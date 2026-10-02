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
  alias ExAtlas.Orchestrator.{Lease, Reaper, TrackingStoreConformance}
  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.{FaultyProvider, LeaseClock, Repo}
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
    {:ok, %{^owner => at}} = Store.expired_leases(now() + 1)
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

    # Slice 2 lifts this: #145.
    test "a pod with a record in the store is left alone" do
      compute = pod()
      :ok = Store.put(TrackingStoreConformance.record(compute.id, %{owner: "m1"}))

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

  defp tick(reaper) do
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end
end
