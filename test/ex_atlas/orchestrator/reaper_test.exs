defmodule ExAtlas.Orchestrator.ReaperTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias ExAtlas.Orchestrator.Reaper
  alias ExAtlas.Providers.Mock
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
end
