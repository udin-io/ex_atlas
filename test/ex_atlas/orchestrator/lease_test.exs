defmodule ExAtlas.Orchestrator.LeaseTest do
  @moduledoc """
  Owner leases on the Ecto store (issue 132): a node renews its lease every
  third of `lease_ttl_ms`, and takes over the signed records of an owner whose
  lease expired, adopting them as a boot adopts its own.

  Each test plays "m1 died, m2 lives" on one SQLite file: m1 spawns and its
  tracker is killed, then the config names m2 and m2's `Lease` starts.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Lease, TrackingStore}
  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
  alias ExAtlas.Test.Repo

  @moduletag :tmp_dir

  # Long enough that no tick fires on its own during a test: each test drives
  # the ticks it needs with `tick!/0`.
  @ttl 60_000

  defmodule RenewFails do
    @moduledoc false
    # The Ecto store whose lease renewal fails: a node cut off from the row
    # that proves it is alive.
    alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

    defdelegate all(), to: Store
    defdelegate get(id), to: Store
    defdelegate claim_expired(claimer, now_ms, rewrite), to: Store
    def renew_lease(_owner, _expires_at_ms), do: {:error, :database_unreachable}
  end

  setup %{tmp_dir: dir} do
    Repo.start!(dir)
    TestOrchestrator.start!(tracking_store: Store)
    TestOrchestrator.put_env(repo: Repo)
    :ok
  end

  defp now, do: System.system_time(:millisecond)

  defp as_owner(owner), do: TestOrchestrator.put_env(reap_owner: owner)

  # A persisted task of `owner` whose node then dies: the pod runs on, the
  # record is all that is left.
  defp orphaned_task(owner, provider \\ :mock) do
    as_owner(owner)

    {:ok, pid, compute} =
      Orchestrator.spawn(
        provider: provider,
        gpu: :h100,
        image: "trainer:latest",
        name: "atlas-lease",
        mode: :task,
        max_runtime_ms: 90 * 60 * 1_000,
        persist: true
      )

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    TestOrchestrator.sync_registry()
    compute
  end

  defp start_lease!(owner, opts \\ []) do
    as_owner(owner)
    opts = Keyword.merge([store: Store, owner: owner, ttl_ms: @ttl], opts)
    pid = start_supervised!({Lease, opts})
    # `init/1` queues the first tick before any call, so this returns after it.
    :sys.get_state(pid)
    pid
  end

  # A Lease that has renewed without a gap for one full ttl, by its own
  # clock, so it claims on its last tick.
  defp held_lease!(owner, opts \\ []) do
    {:ok, clock} = Agent.start_link(&now/0)
    t0 = Agent.get(clock, & &1)
    pid = start_lease!(owner, Keyword.put(opts, :clock, fn -> Agent.get(clock, & &1) end))

    for at <- [t0 + div(@ttl, 2), t0 + @ttl] do
      Agent.update(clock, fn _ -> at end)
      tick!(pid)
    end

    pid
  end

  # Polls `fun` every 10 ms for up to 3 s: adoption runs in its own task.
  defp await(fun, tries \\ 300) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        await(fun, tries - 1)
    end
  end

  defp tick!(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
    :ok
  end

  defp expire!(owner), do: :ok = Store.renew_lease(owner, now() - 1)

  defp lease_expiry(owner) do
    %{rows: [[expires_at]]} =
      Repo.query!("SELECT expires_at FROM atlas_owner_leases WHERE owner = ?1", [owner])

    {:ok, at, 0} = DateTime.from_iso8601(expires_at)
    DateTime.to_unix(at, :millisecond)
  end

  defp put_row!(record) do
    stamp = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT OR REPLACE INTO atlas_tracking_records " <>
        "(id, owner, record, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)",
      [record.id, record[:owner], {:blob, :erlang.term_to_binary(record)}, stamp]
    )
  end

  defp report_finish!(id) do
    Phoenix.PubSub.subscribe(ExAtlas.PubSub, ExAtlas.Orchestrator.Events.topic(id))
    {:ok, %{callback_task_id: task_id}} = Store.get(id)
    :ok = ExAtlas.Callback.ingest(task_id, :finish, %{"exit_code" => 0})
    assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
  end

  defp pod_status(id) do
    {:ok, %{status: status}} = ExAtlas.get_compute(id, provider: :mock)
    status
  end

  describe "renewal" do
    test "renews the lease every third of lease_ttl_ms, until now plus the ttl" do
      test = self()

      clock = fn ->
        at = now()
        send(test, {:clock, at})
        at
      end

      start_lease!("m2", ttl_ms: 1_000, clock: clock)

      assert_receive {:clock, first}, 1_000
      assert_receive {:clock, second}, 2_000
      :sys.get_state(Lease)

      assert lease_expiry("m2") >= second + 1_000
      assert second - first >= 300
      assert second - first < 1_000
    end

    test "takes lease_ttl_ms from config when no :ttl_ms is given" do
      TestOrchestrator.put_env(lease_ttl_ms: 120_000)
      at = now()
      :sys.get_state(start_supervised!({Lease, store: Store, owner: "m2"}))

      assert_in_delta lease_expiry("m2"), at + 120_000, 5_000
    end

    # Under about a database round trip, live nodes would read each other's
    # leases as expired and take each other's tasks.
    test "accepts lease_ttl_ms from one second to one hour, and refuses either side" do
      for ttl <- [1_000, 3_600_000] do
        pid = start_lease!("m2", ttl_ms: ttl)
        assert Process.alive?(pid)
        stop_supervised!(Lease)
      end

      for ttl <- [999, 3, 3_600_001, 0, -90_000, 90.0, "90000"] do
        assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
                 start_supervised({Lease, store: Store, owner: "m2", ttl_ms: ttl})

        assert message =~ "lease_ttl_ms"
      end
    end
  end

  describe "takeover" do
    test "claims and adopts an expired owner's signed record: list_ids names it" do
      %{id: id} = orphaned_task("m1")
      expire!("m1")

      held_lease!("m2")

      assert await(fn -> Orchestrator.list_ids() == [id] end)
      assert {:ok, record} = Store.get(id)
      assert record.owner == "m2"
      assert TrackingStore.sealed?(record)
      assert pod_status(id) == :running
    end

    test "control: claims nothing while the owner's lease is live" do
      %{id: id} = orphaned_task("m1")
      :ok = Store.renew_lease("m1", now() + 10 * @ttl)

      held_lease!("m2")

      assert Orchestrator.list_ids() == []
      assert {:ok, %{owner: "m1"}} = Store.get(id)
    end

    test "deletes a claimed record whose pod is gone, as a boot does" do
      %{id: id} = orphaned_task("m1")
      :ok = Mock.forget(id)
      expire!("m1")

      held_lease!("m2")

      assert await(fn -> Store.get(id) == :error end)
      assert Orchestrator.list_ids() == []
    end

    test "a node that cannot renew its own lease claims nothing" do
      %{id: id} = orphaned_task("m1")
      expire!("m1")

      log = capture_log(fn -> held_lease!("m2", store: RenewFails) end)

      assert log =~ "could not renew the lease of \"m2\""
      assert Orchestrator.list_ids() == []
      assert {:ok, %{owner: "m1"}} = Store.get(id)
    end

    test "leaves an unsigned record of an expired owner, and logs it once" do
      %{id: id} = orphaned_task("m1")
      {:ok, record} = Store.get(id)
      put_row!(Map.delete(record, :mac))
      expire!("m1")

      log =
        capture_log(fn ->
          pid = held_lease!("m2")
          tick!(pid)
        end)

      assert [_once] = String.split(log, "not taking over #{inspect(id)}") |> tl()
      assert Orchestrator.list_ids() == []
      assert {:ok, %{owner: "m1"}} = Store.get(id)
      assert pod_status(id) == :running
    end
  end

  describe "when a node claims" do
    defp clocked_lease!(owner) do
      {:ok, clock} = Agent.start_link(&now/0)
      pid = start_lease!(owner, clock: fn -> Agent.get(clock, & &1) end)
      {pid, clock, Agent.get(clock, & &1)}
    end

    defp tick_at!(pid, clock, at) do
      Agent.update(clock, fn _ -> at end)
      tick!(pid)
    end

    # After a database outage every lease reads expired. The first node back
    # must not take every other live node's tasks.
    test "claims nothing until it has held its own lease for one full ttl" do
      %{id: id} = orphaned_task("m1")
      expire!("m1")
      {lease, clock, t0} = clocked_lease!("m2")

      tick_at!(lease, clock, t0 + @ttl - 1)
      assert {:ok, %{owner: "m1"}} = Store.get(id)

      tick_at!(lease, clock, t0 + @ttl)
      assert {:ok, %{owner: "m2"}} = Store.get(id)
    end

    test "after its own lease lapsed, holds it a full ttl again before claiming" do
      {lease, clock, t0} = clocked_lease!("m2")
      tick_at!(lease, clock, t0 + div(@ttl, 2))
      %{id: id} = orphaned_task("m1")
      expire!("m1")
      as_owner("m2")

      # No renewal for a full ttl: m2's own lease lapsed in between.
      lapsed = t0 + div(@ttl, 2) + @ttl
      tick_at!(lease, clock, lapsed)
      tick_at!(lease, clock, lapsed + @ttl - 1)
      assert {:ok, %{owner: "m1"}} = Store.get(id)

      tick_at!(lease, clock, lapsed + @ttl)
      assert {:ok, %{owner: "m2"}} = Store.get(id)
    end
  end

  describe "adopting what it claimed" do
    # One provider call per claimed record. A large takeover on a slow
    # provider must not hold back the next renewal, or this node's own lease
    # lapses and a third node takes everything again.
    test "runs outside the renewal loop: the Lease ticks while a provider call hangs" do
      %{id: id} = orphaned_task("m1", ExAtlas.Test.FaultyProvider)
      expire!("m1")
      ExAtlas.Test.FaultyProvider.arm(:get_compute, {:block, self()})

      capture_log(fn ->
        lease = held_lease!("m2")
        assert_receive {:blocked, :get_compute, call}, 2_000

        tick!(lease)

        send(call, :release)
        assert await(fn -> Orchestrator.list_ids() == [id] end)
      end)
    end
  end

  describe "records this build would not adopt" do
    # A signed record of a newer release, say, in a rolling deploy: claimed,
    # it would belong to a node that cannot track it.
    test "leaves a signed record of an unknown version with its owner, and logs it once" do
      %{id: id} = orphaned_task("m1")
      {:ok, record} = Store.get(id)
      put_row!(TrackingStore.seal(Map.put(record, :v, 99)))
      expire!("m1")

      log =
        capture_log(fn ->
          pid = held_lease!("m2")
          tick!(pid)
        end)

      assert [_once] = String.split(log, "not taking over #{inspect(id)}") |> tl()
      assert log =~ "unknown schema version 99"
      assert Orchestrator.list_ids() == []
      assert {:ok, %{owner: "m1", v: 99}} = Store.get(id)
    end
  end

  describe "a node that lost a record without a lapse of its own" do
    defp own_task do
      as_owner("m2")

      {:ok, tracker, %{id: id}} =
        Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "trainer:latest",
          name: "atlas-lease",
          mode: :task,
          max_runtime_ms: 90 * 60 * 1_000,
          persist: true
        )

      {tracker, id}
    end

    defp claim_as_m3!(id) do
      to_m3 = fn record -> {:ok, TrackingStore.rewrite(Map.put(record, :owner, "m3"), true)} end
      assert {:ok, [%{id: ^id}]} = Store.claim_expired("m3", now() + 1, to_m3)
    end

    # A database writer, or clock skew, expires m2's lease while m2's own
    # clock says it renewed in time.
    test "releases its tracker once another node owns the record" do
      {tracker, id} = own_task()
      lease = start_lease!("m2")
      expire!("m2")
      claim_as_m3!(id)

      capture_log(fn -> tick!(lease) end)

      refute Process.alive?(tracker)
      assert {:ok, %{owner: "m3"}} = Store.get(id)
      assert pod_status(id) == :running
    end

    # The boot Adopter started the tracker; m3 claimed the record before this
    # node's first renewal.
    test "releases it on the first renewal after boot" do
      {tracker, id} = own_task()
      expire!("m2")
      claim_as_m3!(id)

      capture_log(fn -> start_lease!("m2") end)

      refute Process.alive?(tracker)
      assert {:ok, %{owner: "m3"}} = Store.get(id)
    end
  end

  describe "a node whose lease lapsed" do
    # m2 tracks its own task. Its lease lapses (the clock jumps past it), m3
    # claims the record meanwhile, then m2 renews.
    defp lapse(claimed_by_m3?, opts \\ []) do
      as_owner("m2")

      {:ok, tracker, %{id: id}} =
        Orchestrator.spawn(
          Keyword.merge(
            [
              provider: :mock,
              gpu: :h100,
              image: "trainer:latest",
              name: "atlas-lease",
              mode: :task,
              max_runtime_ms: 90 * 60 * 1_000,
              persist: true
            ],
            opts
          )
        )

      if opts[:callback], do: report_finish!(id)

      {:ok, clock} = Agent.start_link(&now/0)
      lease = start_lease!("m2", clock: fn -> Agent.get(clock, & &1) end)
      lapsed_at = Agent.get(clock, & &1) + @ttl + 1

      if claimed_by_m3? do
        to_m3 = fn record ->
          {:ok, TrackingStore.rewrite(Map.put(record, :owner, "m3"), true)}
        end

        assert {:ok, [%{id: ^id}]} = Store.claim_expired("m3", lapsed_at, to_m3)
      end

      Agent.update(clock, fn _ -> lapsed_at end)
      capture_log(fn -> tick!(lease) end)
      {tracker, id}
    end

    test "stops its tracker of a record another node claimed, and keeps the pod" do
      {tracker, id} = lapse(true)

      refute Process.alive?(tracker)
      assert Orchestrator.list_ids() == []
      assert {:ok, %{owner: "m3"}} = Store.get(id)
      assert pod_status(id) == :running
    end

    # A tracker holding a finish report deletes its pod on a plain stop. The
    # pod and the record are the new owner's now.
    test "stops a tracker that already holds a finish report, and keeps the pod" do
      {tracker, id} =
        lapse(true, callback: "https://app.example.com/atlas/cb", finish_grace_ms: 60_000)

      refute Process.alive?(tracker)
      assert {:ok, %{owner: "m3"}} = Store.get(id)
      assert pod_status(id) == :running
    end

    test "control: keeps its tracker when nobody claimed the record" do
      {tracker, id} = lapse(false)

      assert Process.alive?(tracker)
      assert Orchestrator.list_ids() == [id]
      assert {:ok, %{owner: "m2"}} = Store.get(id)
    end
  end
end
