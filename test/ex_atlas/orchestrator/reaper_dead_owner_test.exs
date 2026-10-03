defmodule ExAtlas.Orchestrator.ReaperDeadOwnerTest do
  @moduledoc """
  The Reaper deletes the untracked pods of a dead owner (issue 144).

  Each test plays "m1 died, m2 lives" on one SQLite file: m1's lease row is
  expired, and m2's `Lease` watches it on clocks the test steps. The control
  pod bills, is untracked and unrecorded, carries the prefix, is past grace
  and is named with dead owner m1. Each refusal changes one of those, or one
  thing about m1 or this node, and nothing else.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Lease, Reaper, TrackingStore, TrackingStoreConformance}
  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.{FaultyProvider, LeaseClock, Repo}
  alias ExAtlas.Test.TrackingStore.{Hooked, NoDeleteExpired}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  @moduletag :tmp_dir

  # Long enough that no Lease tick fires on its own.
  @ttl 60_000
  @window 2 * @ttl
  @name "atlas-m1-notebook-3"

  setup %{tmp_dir: dir} do
    Repo.start!(dir)
    TestOrchestrator.start!(tracking_store: Store)

    TestOrchestrator.put_env(
      repo: Repo,
      reap_owner: "m2",
      reap_grace_ms: 0,
      reap_dead_owner_after_ms: @window
    )

    :ok = Store.renew_lease("m1", now() - 1)
    {:ok, lease: LeaseClock.start!(store: Store, owner: "m2", ttl_ms: @ttl)}
  end

  defp now, do: System.system_time(:millisecond)

  defp dead!(lease), do: LeaseClock.run_for!(lease, @window)

  defp pod(name \\ @name, provider \\ :mock) do
    {:ok, compute} = ExAtlas.spawn_compute(provider: provider, gpu: :h100, image: "x", name: name)
    compute
  end

  defp status(%{id: id}) do
    {:ok, %{status: status}} = ExAtlas.get_compute(id, provider: :mock)
    status
  end

  defp reap(providers \\ [:mock]),
    do: capture_log(fn -> :ok = Reaper.reap_now("atlas-", providers) end)

  defp expiry_iso(owner) do
    {:ok, %{^owner => {at, _mac}}} = Store.expired_leases(now() + 1)
    at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
  end

  describe "a dead owner's untracked pod" do
    test "is deleted, and the log says whose lease stopped when", %{lease: lease} do
      dead!(lease)
      compute = pod()

      log = reap()

      assert status(compute) == :terminated

      assert log =~
               ~s|deleted #{compute.id} (#{@name}): owner "m1" has not renewed its lease | <>
                 "since #{expiry_iso("m1")}, and no connected node reports it"

      refute log =~ "leaving #{compute.id}"
    end

    test "control: a ms before the window ends, it is left alone and logged", %{lease: lease} do
      LeaseClock.run_for!(lease, @window - 1)
      compute = pod()

      log = reap()

      assert status(compute) == :running
      assert log =~ "leaving #{compute.id} (#{@name}) alone"
    end

    test "a periodic Reaper deletes it too, and logs it once", %{lease: lease} do
      TestOrchestrator.put_env(reap_interval_ms: 60_000, reap_providers: [:mock])
      reaper = start_supervised!(Reaper)
      send(reaper, :adoption_complete)
      dead!(lease)
      compute = pod()

      log =
        capture_log(fn ->
          :ok = tick(reaper)
          :ok = tick(reaper)
        end)

      assert status(compute) == :terminated
      assert [_once] = Regex.scan(~r/deleted #{compute.id}/, log)
    end

    test "a delete the provider refuses is logged, and the next tick tries again",
         %{lease: lease} do
      dead!(lease)
      compute = pod(@name, FaultyProvider)
      FaultyProvider.arm(:terminate, {:error_once, ExAtlas.Error.new(:upstream, message: "x")})

      log = reap([FaultyProvider])
      assert status(compute) == :running
      assert log =~ "could not delete #{compute.id} (#{@name}) of dead owner \"m1\" (:upstream)"

      reap([FaultyProvider])
      assert status(compute) == :terminated
    end
  end

  test "a delete that raises or exits is logged, and the tick goes on", %{lease: lease} do
    dead!(lease)
    compute = pod(@name, FaultyProvider)

    for fault <- [:raise, {:exit, :timeout}] do
      FaultyProvider.arm(:terminate, fault)
      log = reap([FaultyProvider])

      assert status(compute) == :running
      assert log =~ "could not delete #{compute.id} (#{@name}) of dead owner \"m1\""
      refute log =~ "simulated terminate failure"
    end
  end

  # The list can take tens of seconds. m1 comes back while it runs.
  test "an owner that renews while its provider lists is not dead at the delete",
       %{lease: lease} do
    dead!(lease)
    compute = pod()
    FaultyProvider.arm(:list_compute, {:block_after, self()})
    reaping = Task.async(fn -> reap([FaultyProvider]) end)
    assert_receive {:blocked, :list_compute, listing}, 2_000

    :ok = Store.renew_lease("m1", now() + @ttl)
    send(listing, :release)
    Task.await(reaping)

    assert status(compute) == :running
  end

  describe "a pod of a dead owner that something else still holds" do
    setup %{lease: lease} do
      dead!(lease)
      :ok
    end

    test "a pod in the Registry is left alone" do
      TestOrchestrator.put_env(reap_owner: "m1")

      {:ok, _pid, compute} =
        Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          name: "atlas-notebook-3",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: false
        )

      TestOrchestrator.put_env(reap_owner: "m2")
      assert compute.name == @name

      reap()

      assert status(compute) == :running
    end

    for status <- [:stopped, :failed] do
      test "a #{status} pod is left alone" do
        compute = pod()
        Mock.set_status(compute.id, unquote(status))

        reap()

        assert status(compute) == unquote(status)
      end
    end

    test "a pod inside the grace window is left alone" do
      TestOrchestrator.put_env(reap_grace_ms: 3_600_000)
      compute = pod()

      reap()

      assert status(compute) == :running
    end
  end

  describe "a pod whose name does not carry the dead owner" do
    setup %{lease: lease} do
      dead!(lease)
      :ok
    end

    test "a live owner's pod is left alone" do
      :ok = Store.renew_lease("m3", now() + 10 * @window)
      compute = pod("atlas-m3-notebook-3")

      reap()

      assert status(compute) == :running
    end

    test "the pod of an owner that never held a lease is left alone" do
      compute = pod("atlas-m4-notebook-3")

      reap()

      assert status(compute) == :running
    end

    for name <- ["atlas-m1", "other-m1-notebook-3", "atlas-M1-notebook-3"] do
      test "#{name} is left alone" do
        compute = pod(unquote(name))

        reap()

        assert status(compute) == :running
      end
    end
  end

  describe "when this node cannot read m1 as dead" do
    test "with no Lease running, the pod is left alone and logged", %{lease: lease} do
      dead!(lease)
      stop_supervised!(Lease)
      compute = pod()

      log = reap()

      assert status(compute) == :running
      assert log =~ "leaving #{compute.id} (#{@name}) alone"
    end

    # On by default since lease rows are signed (#148); the setup sets no
    # `reap_dead_owners`.
    test "with reap_dead_owners unset, a signed dead owner's pod is deleted", %{lease: lease} do
      refute Keyword.has_key?(Application.get_env(:ex_atlas, :orchestrator), :reap_dead_owners)
      dead!(lease)
      compute = pod()

      reap()

      assert status(compute) == :terminated
    end

    # `false` is the off switch. Any value but `true` or none keeps the pod,
    # so a mistyped value fails toward leaving pods alone.
    for value <- [false, "true", "false", nil] do
      test "reap_dead_owners: #{inspect(value)} leaves the pod alone and logged",
           %{lease: lease} do
        TestOrchestrator.put_env(reap_dead_owners: unquote(value))
        dead!(lease)
        compute = pod()

        log = reap()

        assert status(compute) == :running
        assert log =~ "leaving #{compute.id} (#{@name}) alone"
      end
    end

    test "control: reap_dead_owners: true deletes it", %{lease: lease} do
      TestOrchestrator.put_env(reap_dead_owners: true)
      dead!(lease)
      compute = pod()

      reap()

      assert status(compute) == :terminated
    end

    # Issue 148: one INSERT into atlas_owner_leases by a writer without the
    # callback secret. m1's row in the setup is signed, so these replace it.
    test "an expired row with no mac: the pod is left alone and logged", %{lease: lease} do
      :ok = Repo.put_lease!("m1", now() - 1)
      # A new expiry starts a new window; restart so it runs from here.
      lease = LeaseClock.restart!(lease)
      dead!(lease)
      compute = pod()

      log = reap()

      assert status(compute) == :running
      assert log =~ "leaving #{compute.id} (#{@name}) alone"
    end

    test "a row signed under another callback secret: the pod is left alone", %{lease: lease} do
      at = now() - 1
      Application.put_env(:ex_atlas, :callback, secret: String.duplicate("b", 40))
      mac = TrackingStore.lease_mac("m1", at)
      Application.put_env(:ex_atlas, :callback, secret: TestOrchestrator.callback_secret())
      :ok = Repo.put_lease!("m1", at, mac)
      # A new expiry starts a new window; restart so it runs from here.
      lease = LeaseClock.restart!(lease)
      dead!(lease)
      compute = pod()

      reap()

      assert status(compute) == :running
    end

    test "once its own last renewal is a ttl old, the pod is left alone", %{lease: lease} do
      dead!(lease)
      LeaseClock.stall!(lease, @ttl)
      compute = pod()

      reap()

      assert status(compute) == :running
    end

    test "m1 renewed after the last tick: the pod is left alone", %{lease: lease} do
      dead!(lease)
      :ok = Store.renew_lease("m1", now() + @ttl)
      compute = pod()

      reap()

      assert status(compute) == :running
    end

    test "a restarted Lease waits a full new window before the pod goes", %{lease: lease} do
      LeaseClock.run_for!(lease, @window - 1)
      lease = LeaseClock.restart!(lease)
      compute = pod()

      LeaseClock.run_for!(lease, @window - 1)
      reap()
      assert status(compute) == :running

      LeaseClock.run_for!(lease, 1)
      reap()
      assert status(compute) == :terminated
    end

    # The expiry is 26 years old; only the window on the monotonic clock
    # decides.
    test "a lease row backdated by years waits out the whole window", %{lease: lease} do
      :ok = Store.renew_lease("m1", DateTime.to_unix(~U[2000-01-01 00:00:00Z], :millisecond))
      lease = LeaseClock.restart!(lease)
      compute = pod()

      LeaseClock.run_for!(lease, @window - 1)
      reap()
      assert status(compute) == :running

      LeaseClock.run_for!(lease, 1)
      reap()
      assert status(compute) == :terminated
    end

    test "this node's wall clock a day ahead deletes no live owner's pod", %{lease: lease} do
      step = div(@ttl, 3)
      LeaseClock.step!(lease, 86_400_000, step)

      for i <- 1..div(2 * @window, step) do
        :ok = Store.renew_lease("m1", now() + @ttl + i)
        LeaseClock.step!(lease, step, step)
      end

      compute = pod()

      reap()

      assert status(compute) == :running
    end
  end

  # Issue 145. Each "kept" test also has a neighbour: a pod of m1 with no
  # record, which slice 1 deletes in the same tick. It shows the tick ran
  # and read m1 as dead.
  describe "a pod whose record a dead owner still holds" do
    setup %{lease: lease} do
      dead!(lease)
      on_exit(&Hooked.clear/0)
      :ok
    end

    test "an unsigned record: the record goes, then the pod, and the log names both" do
      compute = pod()
      unsigned!(compute)

      log = reap()

      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error

      assert log =~
               ~s|deleted #{compute.id} (#{@name}) and its tracking record: owner "m1" has not | <>
                 "renewed its lease since #{expiry_iso("m1")}, and no connected node reports it"
    end

    test "a signed record this build refuses (a newer version): both go" do
      compute = pod()
      :ok = Store.put(TrackingStore.seal(record(compute, %{v: 99})))

      reap()

      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error
    end

    test "a signed record the Lease would take over is left to the Lease" do
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      :ok = Store.put(TrackingStore.seal(record(compute)))

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
    end

    test "a record of dead m1 on a pod named with live m3: both kept" do
      :ok = Store.renew_lease("m3", now() + 10 * @window)
      {compute, neighbour} = {pod("atlas-m3-notebook-3"), pod("atlas-m1-notebook-4")}
      unsigned!(compute)

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
    end

    for owner <- ["m3", nil] do
      test "a record of owner #{inspect(owner)} on a pod named with dead m1: both kept" do
        :ok = Store.renew_lease("m3", now() + 10 * @window)
        {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
        unsigned!(compute, %{owner: unquote(owner)})

        reap()

        assert status(compute) == :running
        assert {:ok, %{owner: unquote(owner)}} = Store.get(compute.id)
        assert status(neighbour) == :terminated
      end
    end

    # The column is a copy for queries; the record's own `:owner` decides.
    test "a record naming m3 whose owner column a writer set to dead m1: both kept" do
      :ok = Store.renew_lease("m3", now() + 10 * @window)
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      unsigned!(compute, %{owner: "m3"})
      Repo.query!("UPDATE atlas_tracking_records SET owner = 'm1' WHERE id = ?1", [compute.id])

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m3"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
    end

    test "a record of another provider whose id matches the pod's: both kept" do
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      unsigned!(compute, %{provider: FaultyProvider})

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
    end

    test "a record read that raises, throws or exits keeps the pod, and the tick goes on" do
      TestOrchestrator.put_env(tracking_store: Hooked)
      compute = pod()
      unsigned!(compute)

      for fault <- [
            fn -> raise "db down" end,
            fn -> throw(:db_down) end,
            fn -> exit(:db_down) end
          ] do
        Hooked.hook_get(fault)

        log = reap()

        assert status(compute) == :running
        assert log =~ "tracking store raised for #{compute.id}"
      end

      Hooked.clear()
      reap()
      assert status(compute) == :terminated
    end

    test "reap_dead_owners: false keeps both" do
      TestOrchestrator.put_env(reap_dead_owners: false)
      compute = pod()
      unsigned!(compute)

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
    end

    test "a store without delete_expired/3 keeps both" do
      TestOrchestrator.put_env(tracking_store: NoDeleteExpired)
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      unsigned!(compute)

      log = reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
      refute log =~ "could not delete the tracking record"
    end

    # The stale struct: the Reaper read the record, then m3 claimed it.
    test "a record m3 claims after the Reaper read it: pod running, record m3's" do
      TestOrchestrator.put_env(tracking_store: Hooked)
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      unsigned!(compute)

      Hooked.hook(fn ->
        {:ok, [_]} = Store.claim_expired("m3", now(), &{:ok, Map.put(&1, :owner, "m3")})
        :continue
      end)

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m3"}} = Store.get(compute.id)
      assert status(neighbour) == :terminated
    end

    test "m1 renews after the Reaper read it dead: both kept" do
      TestOrchestrator.put_env(tracking_store: Hooked)
      compute = pod()
      unsigned!(compute)

      Hooked.hook(fn ->
        :ok = Store.renew_lease("m1", now() + @ttl)
        :continue
      end)

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
    end

    test "control: with a hook that changes nothing, both go" do
      TestOrchestrator.put_env(tracking_store: Hooked)
      compute = pod()
      unsigned!(compute)
      Hooked.hook(fn -> :continue end)

      reap()

      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error
    end

    test "a record delete that fails or raises keeps both, and the next tick deletes both" do
      TestOrchestrator.put_env(tracking_store: Hooked)
      {compute, neighbour} = {pod(), pod("atlas-m1-notebook-4")}
      unsigned!(compute)

      faults = [
        fn -> {:replace, {:error, :busy}} end,
        fn -> raise "db down" end,
        fn -> throw(:db_down) end,
        fn -> exit(:db_down) end
      ]

      for fault <- faults do
        Hooked.hook(fault)
        log = reap()

        assert status(compute) == :running
        assert {:ok, %{owner: "m1"}} = Store.get(compute.id)

        assert log =~
                 "could not delete the tracking record of #{compute.id} (#{@name}) of dead " <>
                   ~s|owner "m1"|

        refute log =~ "db down"
      end

      assert status(neighbour) == :terminated

      Hooked.clear()
      reap()

      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error
    end

    test "a pod delete that fails after the record went: the next tick deletes the pod" do
      compute = pod(@name, FaultyProvider)
      unsigned!(compute, %{provider: FaultyProvider})
      FaultyProvider.arm(:terminate, {:error_once, ExAtlas.Error.new(:upstream, message: "x")})

      log = reap([FaultyProvider])

      assert status(compute) == :running
      assert Store.get(compute.id) == :error

      assert log =~
               "deleted the tracking record of #{compute.id} (#{@name}) of dead owner \"m1\", " <>
                 "but could not delete the pod (:upstream); the next tick deletes it"

      log = reap([FaultyProvider])

      assert status(compute) == :terminated
      assert log =~ "deleted #{compute.id} (#{@name}): owner \"m1\""
    end

    test "once this node's own last renewal is a ttl old, both kept", %{lease: lease} do
      LeaseClock.stall!(lease, @ttl)
      compute = pod()
      unsigned!(compute)

      reap()

      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)
    end
  end

  describe "a pod whose record a dead owner holds, across restarts" do
    test "control: a ms before the window ends both stay; at the window both go",
         %{lease: lease} do
      LeaseClock.run_for!(lease, @window - 1)
      compute = pod()
      unsigned!(compute)

      reap()
      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)

      LeaseClock.run_for!(lease, 1)
      reap()
      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error
    end

    test "a restarted Lease waits a full new window", %{lease: lease} do
      LeaseClock.run_for!(lease, @window - 1)
      lease = LeaseClock.restart!(lease)
      compute = pod()
      unsigned!(compute)

      LeaseClock.run_for!(lease, @window - 1)
      reap()
      assert status(compute) == :running
      assert {:ok, %{owner: "m1"}} = Store.get(compute.id)

      LeaseClock.run_for!(lease, 1)
      reap()
      assert status(compute) == :terminated
    end

    test "record gone, pod delete failed, Reaper restarted: the next tick deletes the pod",
         %{lease: lease} do
      TestOrchestrator.put_env(reap_interval_ms: 60_000, reap_providers: [FaultyProvider])
      dead!(lease)
      compute = pod(@name, FaultyProvider)
      unsigned!(compute, %{provider: FaultyProvider})
      FaultyProvider.arm(:terminate, {:error_once, ExAtlas.Error.new(:upstream, message: "x")})

      capture_log(fn -> :ok = tick(periodic_reaper!()) end)
      assert Store.get(compute.id) == :error
      assert status(compute) == :running

      stop_supervised!(Reaper)
      capture_log(fn -> :ok = tick(periodic_reaper!()) end)

      assert status(compute) == :terminated
      assert Store.get(compute.id) == :error
    end

    test "record and pod gone, Reaper restarted: the next tick deletes nothing more",
         %{lease: lease} do
      TestOrchestrator.put_env(reap_interval_ms: 60_000, reap_providers: [:mock])
      dead!(lease)
      compute = pod()
      unsigned!(compute)

      log = capture_log(fn -> :ok = tick(periodic_reaper!()) end)
      assert [_once] = Regex.scan(~r/deleted #{compute.id}/, log)
      assert status(compute) == :terminated

      stop_supervised!(Reaper)
      log = capture_log(fn -> :ok = tick(periodic_reaper!()) end)

      refute log =~ compute.id
      assert Store.get(compute.id) == :error
    end
  end

  defp record(compute, overrides \\ %{}),
    do: TrackingStoreConformance.record(compute.id, Map.merge(%{owner: "m1"}, overrides))

  # The conformance record's `:mac` is no signature this node's key makes.
  defp unsigned!(compute, overrides \\ %{}) do
    record = record(compute, overrides)
    refute TrackingStore.sealed?(record)
    :ok = Store.put(record)
  end

  defp periodic_reaper! do
    reaper = start_supervised!(Reaper)
    send(reaper, :adoption_complete)
    reaper
  end

  defp tick(reaper) do
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end
end
