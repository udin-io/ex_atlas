defmodule ExAtlas.Orchestrator.ReaperTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias ExAtlas.Orchestrator.Reaper
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.FakeVast
  alias ExAtlas.Test.FaultyProvider
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
  alias ExAtlas.Test.TrackingStore.Memory

  setup do
    TestOrchestrator.start!()
    on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)

    :ok
  end

  defp spawn_untracked(opts \\ []) do
    [provider: :mock, gpu: :h100, image: "x", name: "atlas-orphan"]
    |> Keyword.merge(opts)
    |> ExAtlas.spawn_compute()
  end

  test "an untracked resource past the grace window is reclaimed" do
    TestOrchestrator.put_env(reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked()

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "an untracked resource still provisioning past the grace window is reclaimed" do
    # A booting pod bills. Runpod v1's desiredStatus=RUNNING listing included
    # it; v2 reports it as PROVISIONING or STARTING.
    TestOrchestrator.put_env(reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked()
    Mock.set_status(compute.id, :provisioning)

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  for status <- [:stopped, :failed] do
    test "an untracked #{status} resource is left alone" do
      TestOrchestrator.put_env(reap_grace_ms: 0)
      {:ok, compute} = spawn_untracked()
      Mock.set_status(compute.id, unquote(status))

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: unquote(status)}} =
               ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  test "a resource whose name lacks the prefix is never touched" do
    TestOrchestrator.put_env(reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked(name: "someone-elses-pod")

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a tracked resource is never touched" do
    TestOrchestrator.put_env(reap_grace_ms: 0)

    {:ok, _pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        name: "atlas-tracked",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: false
      )

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a resource younger than the grace window is left alone" do
    # No tracker yet is not the same as no tracker ever: `Orchestrator.spawn/1`
    # and the respawn path both create the resource before registering it.
    {:ok, compute} = spawn_untracked()

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a resource is not reaped while its own spawn call is still in flight" do
    TestOrchestrator.put_env(reap_grace_ms: 60_000)

    FaultyProvider.arm(:spawn_compute, {:block_after, self()})

    spawning =
      Task.async(fn ->
        ExAtlas.Orchestrator.spawn(
          provider: FaultyProvider,
          gpu: :h100,
          image: "x",
          name: "atlas-mid-spawn",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: false
        )
      end)

    # The provider has created the resource; the caller has not seen the reply,
    # so nothing is in the registry yet. This is the window the Reaper used to
    # walk straight into — and on the respawn path each tick it does so burns
    # one respawn from the budget.
    assert_receive {:blocked, :spawn_compute, provider_pid}, 2_000
    :ok = Reaper.reap_now("atlas-", [FaultyProvider])

    send(provider_pid, :release)
    assert {:ok, _pid, compute} = Task.await(spawning)

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  describe "with a :reap_owner" do
    # Each refusal below fails one clause of the rule only: the pod is
    # untracked, unrecorded, running, prefixed, past grace and on a single
    # node, so the control's pod differs from it by name alone.
    setup do
      TestOrchestrator.put_env(reap_owner: "b", reap_grace_ms: 0)
    end

    test "this node's own untracked pod is reclaimed" do
      {:ok, compute} = spawn_untracked(name: "atlas-b-train-1")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "another owner's untracked pod is left alone" do
      {:ok, compute} = spawn_untracked(name: "atlas-a-train-1")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "a pod named before owners existed is left alone" do
      # v0.7.0 named it; its first segment reads as owner "train".
      {:ok, compute} = spawn_untracked(name: "atlas-train-42")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "an owner that starts with this owner's name is another owner" do
      {:ok, compute} = spawn_untracked(name: "atlas-bb-x")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    # Another tool's pod on the same account: not ours, not logged either.
    test "a pod without the prefix is neither touched nor logged" do
      {:ok, compute} = spawn_untracked(name: "billing-db")
      {:ok, control} = spawn_untracked(name: "atlas-a-train-1")

      log = capture_log(fn -> :ok = Reaper.reap_now("atlas-", [:mock]) end)

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert log =~ "leaving #{control.id}"
      refute log =~ "leaving #{compute.id}"
    end

    test "a name with no dash after the owner carries no owner and is left alone" do
      {:ok, compute} = spawn_untracked(name: "atlas-b")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "a periodic Reaper logs a pod it leaves alone once, with its id and owner" do
      TestOrchestrator.put_env(
        tracking_store: false,
        reap_interval_ms: 60_000,
        reap_providers: [:mock],
        reap_name_prefix: "atlas-"
      )

      reaper = start_supervised!(Reaper)
      {:ok, compute} = spawn_untracked(name: "atlas-a-train-1")

      log =
        capture_log(fn ->
          :ok = tick(reaper)
          :ok = tick(reaper)
        end)

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert [_once] = Regex.scan(~r/leaving #{compute.id} \(atlas-a-train-1\) alone/, log)
      assert log =~ ~s|carries owner "a"|
      assert log =~ "or a name from before owners existed"
    end
  end

  test "an invalid :reap_owner reaps nothing and logs an error" do
    # Control: "an untracked resource past the grace window is reclaimed",
    # the same pod with no owner set.
    TestOrchestrator.put_env(reap_owner: "Not Valid", reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked()

    log = capture_log(fn -> :ok = Reaper.reap_now("atlas-", [:mock]) end)

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    assert log =~ "[error]"
    assert log =~ ":reap_owner"
    refute log =~ "Not Valid"
  end

  describe "resources the tracking store knows about" do
    setup do
      TestOrchestrator.put_env(tracking_store: Memory, reap_grace_ms: 0)
      start_supervised!(Memory)
      :ok
    end

    test "are spared even with no tracker and no grace left" do
      # This is the deploy: the pod is old, prefix-matching, and has no
      # registry entry, because the node that spawned it restarted. Before the
      # store existed, this is the tick that destroyed hours of GPU work.
      {:ok, compute} = spawn_untracked()
      :ok = Memory.put(record_for(compute))

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "someone else's pod is still reclaimed" do
      # The store makes the Reaper more careful, not blind: an id nothing
      # recorded is still an orphan.
      {:ok, ours} = spawn_untracked()
      {:ok, theirs} = spawn_untracked()
      :ok = Memory.put(record_for(ours))

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(ours.id, provider: :mock)
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(theirs.id, provider: :mock)
    end
  end

  describe "the adoption gate" do
    setup do
      TestOrchestrator.put_env(
        tracking_store: Memory,
        reap_grace_ms: 0,
        # A long interval, so the only ticks are the ones a test sends.
        reap_interval_ms: 60_000,
        reap_providers: [:mock],
        reap_name_prefix: "atlas-"
      )

      start_supervised!(Memory)

      {:ok, reaper: start_supervised!(Reaper)}
    end

    test "nothing is reaped until adoption has settled", %{reaper: reaper} do
      {:ok, compute} = spawn_untracked()

      :ok = tick(reaper)
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)

      # Adoption is what closes the window in which live compute of ours has no
      # tracker yet. Only once it has run is the registry a fair test of "is
      # this ours" — before then, every adoptable pod looks like an orphan.
      send(reaper, :adoption_complete)
      :ok = tick(reaper)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "a store that could not be read disables reaping for the boot", %{reaper: reaper} do
      {:ok, compute} = spawn_untracked()

      send(reaper, :adoption_failed)
      :ok = tick(reaper)
      :ok = tick(reaper)

      # We cannot tell which running pods are ours, and a DELETE is not
      # recoverable. Leaking spend until an operator reads the warning is by
      # far the cheaper mistake.
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  # A provider whose list raises: RunPod's with no API key configured, which
  # the default `reap_providers: [:runpod]` lists on a Vast-only host.
  defmodule RaisingListProvider do
    @moduledoc false
    def capabilities, do: []

    def list_compute(_filters, _ctx),
      do: raise(ExAtlas.Error.new(:unauthorized, message: "no API key configured"))
  end

  # A list that exits: an HTTP pool checkout that times out.
  defmodule ExitingListProvider do
    @moduledoc false
    def capabilities, do: []
    def list_compute(_filters, _ctx), do: exit({:timeout, {NimblePool, :checkout, [:pool]}})
  end

  describe "a provider whose list raises or exits" do
    setup do
      TestOrchestrator.put_env(
        tracking_store: false,
        reap_grace_ms: 0,
        reap_interval_ms: 60_000,
        reap_providers: [RaisingListProvider, ExitingListProvider, :mock],
        reap_name_prefix: "atlas-"
      )

      {:ok, reaper: start_supervised!(Reaper)}
    end

    test "does not stop the tick: the next provider's orphan is reclaimed", %{reaper: reaper} do
      {:ok, compute} = spawn_untracked()

      log = capture_log(fn -> assert :ticked = surviving_tick(reaper) end)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert log =~ inspect(RaisingListProvider)
      assert log =~ ":unauthorized"
      refute log =~ "no API key configured"
      assert log =~ "listing #{inspect(ExitingListProvider)} exited"
      refute log =~ ":checkout"
    end
  end

  describe "without a tracking store" do
    setup do
      TestOrchestrator.put_env(
        tracking_store: false,
        reap_grace_ms: 0,
        reap_interval_ms: 60_000,
        reap_providers: [:mock],
        reap_name_prefix: "atlas-"
      )

      {:ok, reaper: start_supervised!(Reaper)}
    end

    test "reaping starts at once, exactly as it did before adoption existed",
         %{reaper: reaper} do
      {:ok, compute} = spawn_untracked()

      :ok = tick(reaper)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  # `:reap` is the Reaper's own periodic message. Sending it and then
  # synchronising on the process is how a test observes exactly one full tick
  # without waiting on the wall clock.
  defp tick(reaper) do
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end

  defp surviving_tick(reaper) do
    :ok = tick(reaper)
    :ticked
  catch
    :exit, reason -> {:crashed, reason}
  end

  defp record_for(compute) do
    %{
      v: ExAtlas.Orchestrator.TrackingStore.version(),
      id: compute.id,
      provider: :mock,
      opts: [provider: :mock, mode: :task, persist: true],
      spawned_at_ms: System.system_time(:millisecond) - 3 * 60 * 60 * 1_000,
      max_runtime_ms: false,
      respawns: 0,
      callback_task_id: nil,
      report: nil,
      mode: :task,
      user_id: nil
    }
  end

  describe "on Vast" do
    setup do
      bypass = Bypass.open()
      previous = Application.get_env(:ex_atlas, :vast)

      Application.put_env(:ex_atlas, :vast,
        api_key: "vast-test-key",
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_atlas, :vast, previous),
          else: Application.delete_env(:ex_atlas, :vast)
      end)

      {:ok, bypass: bypass}
    end

    # A rent that answered 5xx or timed out may have rented, and nothing
    # tracks what it rented (risk 54).
    test "destroys an untracked atlas- instance past the grace window, leaves a younger one", %{
      bypass: bypass
    } do
      TestOrchestrator.put_env(reap_grace_ms: 60 * 60 * 1_000)
      now = System.os_time(:second)

      instances = [
        FakeVast.instance(%{"id" => 1, "label" => "atlas-old", "start_date" => now - 7_200}),
        FakeVast.instance(%{"id" => 2, "label" => "atlas-young", "start_date" => now - 300}),
        FakeVast.instance(%{"id" => 3, "label" => "other-old", "start_date" => now - 7_200})
      ]

      Bypass.expect(bypass, "GET", "/api/v1/instances", fn conn ->
        FakeVast.json(conn, 200, %{"instances" => instances, "next_token" => nil})
      end)

      test_pid = self()

      Bypass.expect_once(bypass, "DELETE", "/api/v0/instances/:id", fn conn ->
        send(test_pid, {:destroyed, List.last(conn.path_info)})
        FakeVast.json(conn, 200, %{"success" => true})
      end)

      :ok = Reaper.reap_now("atlas-", [:vast])

      assert_received {:destroyed, "1"}
      refute_received {:destroyed, _}
    end

    # A Vast label is free text, so `atlas-` can name an instance ExAtlas never
    # rented. The default leaves Vast out; a host opts in (#118). A tick under
    # the default would list the real RunPod account wherever RUNPOD_API_KEY is
    # set, so this reads the coverage the tick uses instead.
    test "the default :reap_providers covers :runpod and not :vast" do
      assert Application.get_env(:ex_atlas, :orchestrator, [])[:reap_providers] == nil

      refute Reaper.covers?(:vast)
      refute Reaper.covers?(ExAtlas.Providers.Vast)
      assert Reaper.covers?(:runpod)
    end

    test "control: a periodic Reaper with :vast in :reap_providers lists Vast", %{
      bypass: bypass
    } do
      reaper = start_vast_reaper(bypass, reap_providers: [:vast])

      :ok = tick(reaper)

      assert_received :listed
    end

    test "with :vast opted in, an instance a live tracker holds is never destroyed", %{
      bypass: bypass
    } do
      TestOrchestrator.put_env(reap_grace_ms: 0)
      old = System.os_time(:second) - 7_200

      instances = [
        FakeVast.instance(%{"id" => 1, "label" => "atlas-tracked", "start_date" => old}),
        FakeVast.instance(%{"id" => 2, "label" => "atlas-orphan", "start_date" => old}),
        FakeVast.instance(%{"id" => 3, "label" => "users-own", "start_date" => old})
      ]

      {:ok, _} = Registry.register(ExAtlas.Orchestrator.ComputeRegistry, {:compute, "1"}, nil)

      Bypass.expect(bypass, "GET", "/api/v1/instances", fn conn ->
        FakeVast.json(conn, 200, %{"instances" => instances, "next_token" => nil})
      end)

      test_pid = self()

      Bypass.expect_once(bypass, "DELETE", "/api/v0/instances/:id", fn conn ->
        send(test_pid, {:destroyed, List.last(conn.path_info)})
        FakeVast.json(conn, 200, %{"success" => true})
      end)

      :ok = Reaper.reap_now("atlas-", [:vast])

      # Control: the untracked atlas- instance goes in the same pass.
      assert_received {:destroyed, "2"}
      refute_received {:destroyed, _}
    end
  end

  defp start_vast_reaper(bypass, env) do
    TestOrchestrator.put_env(
      [tracking_store: false, reap_grace_ms: 0, reap_interval_ms: 60_000] ++ env
    )

    test_pid = self()

    Bypass.stub(bypass, "GET", "/api/v1/instances", fn conn ->
      send(test_pid, :listed)
      FakeVast.json(conn, 200, %{"instances" => [], "next_token" => nil})
    end)

    start_supervised!(Reaper)
  end
end
