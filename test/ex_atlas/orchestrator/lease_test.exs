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
  alias ExAtlas.Test.{LeaseClock, Repo}

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

  defmodule OddClaims do
    @moduledoc false
    # A custom store whose claim answers a shape the contract does not allow.
    alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

    defdelegate get(id), to: Store
    defdelegate renew_lease(owner, expires_at_ms), to: Store
    def claim_expired(_claimer, _now_ms, _rewrite), do: {:ok, :not_a_list}
  end

  defmodule Flaky do
    @moduledoc false
    # The Ecto store whose lease calls fail while the test lists them in
    # `config :ex_atlas, :lease_test_failing`: a node cut off for one tick.
    alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

    defdelegate all(), to: Store
    defdelegate get(id), to: Store
    defdelegate claim_expired(claimer, now_ms, rewrite), to: Store

    def renew_lease(owner, at),
      do:
        if(failing?(:renew_lease), do: {:error, :unreachable}, else: Store.renew_lease(owner, at))

    def expired_leases(now),
      do:
        if(failing?(:expired_leases), do: {:error, :unreachable}, else: Store.expired_leases(now))

    defp failing?(call), do: call in Application.get_env(:ex_atlas, :lease_test_failing, [])
  end

  defmodule ListedExpired do
    @moduledoc false
    # A custom store whose expired_leases/1 answers a list, outside the contract.
    alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

    defdelegate all(), to: Store
    defdelegate get(id), to: Store
    defdelegate renew_lease(owner, expires_at_ms), to: Store
    defdelegate claim_expired(claimer, now_ms, rewrite), to: Store
    def expired_leases(_now_ms), do: {:ok, [{"m1", 1}]}
  end

  defmodule NoExpiredLeases do
    @moduledoc false
    # A custom store with leases and claims, written before expired_leases/1.
    alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store

    defdelegate all(), to: Store
    defdelegate get(id), to: Store
    defdelegate renew_lease(owner, expires_at_ms), to: Store
    defdelegate claim_expired(claimer, now_ms, rewrite), to: Store
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

  defp lease_row(owner) do
    {:ok, %{^owner => {at, mac}}} = Store.expired_leases(now() + 3_600_000)
    {at, mac}
  end

  defp with_secret(secret, fun) do
    previous = Application.get_env(:ex_atlas, :callback)
    Application.put_env(:ex_atlas, :callback, secret: secret)

    try do
      fun.()
    after
      Application.put_env(:ex_atlas, :callback, previous)
    end
  end

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

  describe ":reap_dead_owner_after_ms" do
    # A window under two ttls reads a live owner's 90 s database blip as death;
    # one over a day lets an orphan bill for a day.
    test "accepts two lease ttls and 24 hours, and refuses either side, 0 and non-integers" do
      for window <- [2 * @ttl, 86_400_000] do
        TestOrchestrator.put_env(reap_dead_owner_after_ms: window)
        pid = start_lease!("m2")
        assert Process.alive?(pid)
        stop_supervised!(Lease)
      end

      for window <- [2 * @ttl - 1, 86_400_001, 0, -900_000, 900_000.0, "900000"] do
        TestOrchestrator.put_env(reap_dead_owner_after_ms: window)

        assert {:error, {{%ArgumentError{message: message}, _stack}, _child}} =
                 start_supervised({Lease, store: Store, owner: "m2", ttl_ms: @ttl})

        assert message =~ "reap_dead_owner_after_ms"
        assert message =~ "from #{2 * @ttl} to 86400000"
      end
    end

    test "the bounds follow lease_ttl_ms: 2 x 1 s is accepted at a 1 s ttl" do
      TestOrchestrator.put_env(reap_dead_owner_after_ms: 2_000)
      pid = start_lease!("m2", ttl_ms: 1_000)

      assert Process.alive?(pid)
    end

    # At a ttl over 7.5 minutes, 15 minutes is under two ttls.
    test "with no window set, starts at any lease_ttl_ms, the one-hour maximum included" do
      for ttl <- [1_000, @ttl, 3_600_000] do
        pid = start_lease!("m2", ttl_ms: ttl)
        assert Process.alive?(pid)
        stop_supervised!(Lease)
      end
    end
  end

  describe "dead_owners/0" do
    # The shortest window the setting allows, so a test steps through it in
    # six renewals.
    @window 2 * @ttl
    @step div(@ttl, 3)

    setup do
      TestOrchestrator.put_env(reap_dead_owner_after_ms: @window)
      on_exit(fn -> Application.delete_env(:ex_atlas, :lease_test_failing) end)
    end

    defp watching_lease!(owner, opts \\ []) do
      as_owner(owner)
      LeaseClock.start!(Keyword.merge([store: Store, owner: owner, ttl_ms: @ttl], opts))
    end

    defp fail!(calls), do: Application.put_env(:ex_atlas, :lease_test_failing, calls)

    test "an owner expired and unchanged for the whole window is dead; a ms short, it is not" do
      expire!("m1")
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, 1)
      assert Lease.dead_owners() == %{"m1" => lease_expiry("m1")}
    end

    test "control: an owner that renews mid-window, still expired, starts a new window" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, div(@window, 2))

      :ok = Store.renew_lease("m1", lease_expiry("m1") - 1_000)
      LeaseClock.run_for!(lease, @window)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, @step)
      assert Lease.dead_owners() == %{"m1" => lease_expiry("m1")}
    end

    test "control: an owner that renews its lease into the future is never dead" do
      :ok = Store.renew_lease("m1", now() + 10 * @window)
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Lease.dead_owners() == %{}
    end

    # A node that just booted, or came back from its own outage, waits a full
    # window before it reads anyone as dead.
    test "a Lease restarted near the end of a window waits a full new window" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window - @step)

      lease = LeaseClock.restart!(lease)

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, 1)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "one failed renewal of its own lease clears the watch for a full new window" do
      expire!("m1")
      lease = watching_lease!("m2", store: Flaky)
      LeaseClock.run_for!(lease, @window)
      assert Map.keys(Lease.dead_owners()) == ["m1"]

      fail!([:renew_lease])
      capture_log(fn -> LeaseClock.run_for!(lease, @step) end)
      assert Lease.dead_owners() == %{}

      fail!([])
      LeaseClock.run_for!(lease, @window)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, @step)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "one failed read of the expired leases clears the watch for a full new window" do
      expire!("m1")
      lease = watching_lease!("m2", store: Flaky)
      LeaseClock.run_for!(lease, @window)

      fail!([:expired_leases])
      log = capture_log(fn -> LeaseClock.run_for!(lease, @step) end)
      assert log =~ "could not read expired leases"
      assert Lease.dead_owners() == %{}

      fail!([])
      LeaseClock.run_for!(lease, @window)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, @step)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    # The wall clock jumped a full ttl between two renewals: by it, this
    # node's own lease lapsed, and every live owner may have read expired.
    test "a gap of a full ttl between its renewals on the wall clock starts a new window" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window - @step)

      LeaseClock.step!(lease, @ttl, @step)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, 1)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "a gap of a full ttl between its renewals on the monotonic clock starts a new window" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window - @step)

      LeaseClock.step!(lease, @step, @ttl)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, 1)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "nothing is dead once its own last renewal is a ttl old" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window)

      LeaseClock.stall!(lease, @ttl)

      assert Lease.dead_owners() == %{}
    end

    # The watch is up to a third of a ttl old at the call. An owner back
    # from the dead renews in that time, before its first pod is past grace.
    test "an owner that renewed since the last tick is not dead" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window)

      :ok = Store.renew_lease("m1", lease_expiry("m1") - 1_000)
      assert Lease.dead_owners() == %{}

      :ok = Store.renew_lease("m1", now() + @ttl)
      assert Lease.dead_owners() == %{}
    end

    # Each moves one source away from the monotonic clock: an expiry 26 years
    # old, or this node's wall clock a day ahead of a live owner's lease.
    test "a lease row backdated by years waits out the whole window" do
      :ok = Store.renew_lease("m1", DateTime.to_unix(~U[2000-01-01 00:00:00Z], :millisecond))
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}

      LeaseClock.run_for!(lease, 1)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    # m1 renews on its own clock every step; by m2's clock its lease is a day
    # in the past every time m2 reads it.
    test "a wall clock a day ahead makes no live owner dead" do
      :ok = Store.renew_lease("m1", now() + @ttl)
      lease = watching_lease!("m2")
      LeaseClock.step!(lease, 86_400_000, @step)

      for i <- 1..div(2 * @window, @step) do
        :ok = Store.renew_lease("m1", now() + @ttl + i)
        LeaseClock.step!(lease, @step, @step)
      end

      assert Lease.dead_owners() == %{}
    end

    test "an expired lease whose owner no pod name can carry is never dead" do
      for owner <- ["M1", "a-b", String.duplicate("a", 33)], do: expire!(owner)
      expire!("m1")
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    # Issue 148: anyone who can write `atlas_owner_leases` writes these rows.
    # Each row below differs from m1's own signed row in one thing only.
    test "an expired row with no mac is never dead; control: m1's own signed row is" do
      expire!("m1")
      :ok = Repo.put_lease!("m5", now() - 1)
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "a row signed under another callback secret is never dead" do
      at = now() - 1
      mac = with_secret(String.duplicate("b", 40), fn -> TrackingStore.lease_mac("m5", at) end)
      :ok = Repo.put_lease!("m5", at, mac)
      expire!("m1")
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "m1's mac copied onto another owner's row is never dead" do
      expire!("m1")
      {at, mac} = lease_row("m1")
      :ok = Repo.put_lease!("m5", at, mac)
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    # A stale copy: m1's signed row, its expiry moved and its mac kept.
    test "m1's row with its expiry moved and its mac kept is never dead" do
      expire!("m1")
      {at, mac} = lease_row("m1")
      :ok = Repo.put_lease!("m1", at - 60_000, mac)
      lease = watching_lease!("m2")

      LeaseClock.run_for!(lease, 2 * @window)

      assert Lease.dead_owners() == %{}
    end

    # The confirming read at the call verifies too: m1 dies signed, then a
    # writer swaps in an unsigned row with the same expiry.
    test "a row that loses its mac after the window is not dead at the call" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window)
      assert Map.keys(Lease.dead_owners()) == ["m1"]

      {at, _mac} = lease_row("m1")
      :ok = Repo.put_lease!("m1", at)

      assert Lease.dead_owners() == %{}
    end

    # Each rewrite of m1's row, then a restart: the verdict holds.
    test "after a signed renewal and a restart, m1 is dead after a full window" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @step)
      :ok = Store.renew_lease("m1", now() - 2)

      lease = LeaseClock.restart!(lease)

      LeaseClock.run_for!(lease, @window - 1)
      assert Lease.dead_owners() == %{}
      LeaseClock.run_for!(lease, 1)
      assert Map.keys(Lease.dead_owners()) == ["m1"]
    end

    test "after a 0.9.0-style renewal and a restart, m1 is never dead" do
      expire!("m1")
      lease = watching_lease!("m2")
      LeaseClock.run_for!(lease, @window)
      # Another expiry under m1's old mac. `now() - 2` matched the old one
      # whenever 1 ms passed since `expire!/1`, and m1 read dead.
      {at, mac} = lease_row("m1")
      :ok = Repo.put_lease!("m1", at - 1, mac)

      lease = LeaseClock.restart!(lease)

      LeaseClock.run_for!(lease, 2 * @window)
      assert Lease.dead_owners() == %{}
    end

    test "a store whose expired_leases/1 answers a list: nothing dead, the Lease runs, logged" do
      log =
        capture_log(fn ->
          lease = watching_lease!("m2", store: ListedExpired)
          LeaseClock.run_for!(lease, 2 * @window)
          assert Lease.dead_owners() == %{}
        end)

      assert Process.alive?(Process.whereis(Lease))
      assert log =~ "could not read expired leases"
    end

    test "answers %{} when no Lease runs" do
      assert Lease.dead_owners() == %{}
    end

    test "a store without expired_leases/1: nothing dead, and nothing logged" do
      expire!("m1")

      log =
        capture_log(fn ->
          lease = watching_lease!("m2", store: NoExpiredLeases)
          LeaseClock.run_for!(lease, 2 * @window)
        end)

      assert Lease.dead_owners() == %{}
      refute log =~ "[warning]"
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

  describe "what the Lease survives" do
    test "a message it does not expect" do
      lease = start_lease!("m2")
      send(lease, {:unexpected, :message})

      assert :ok = tick!(lease)
      assert Process.alive?(lease)
    end

    test "a store whose claim answers a shape outside the contract" do
      log = capture_log(fn -> held_lease!("m2", store: OddClaims) end)

      assert Process.alive?(Process.whereis(Lease))
      assert log =~ "could not claim"
    end
  end

  describe "one takeover at a time" do
    test "claims nothing new while the last takeover is still adopting" do
      %{id: first} = orphaned_task("m1", ExAtlas.Test.FaultyProvider)
      expire!("m1")
      ExAtlas.Test.FaultyProvider.arm(:get_compute, {:block, self()})

      capture_log(fn ->
        lease = held_lease!("m2")
        assert_receive {:blocked, :get_compute, call}, 2_000

        %{id: second} = orphaned_task("m3")
        expire!("m3")
        as_owner("m2")
        tick!(lease)
        assert {:ok, %{owner: "m3"}} = Store.get(second)

        # Once the first adoption ends, a tick claims the second.
        send(call, :release)
        assert await(fn -> first in Orchestrator.list_ids() end)

        assert await(fn ->
                 tick!(lease)
                 match?({:ok, %{owner: "m2"}}, Store.get(second))
               end)
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
