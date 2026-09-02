defmodule ExAtlas.Orchestrator.ComputeServerTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Callback
  alias ExAtlas.Orchestrator.{ComputeSupervisor, Events}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.FaultyProvider

  setup do: ExAtlas.Test.Orchestrator.start!()

  test "spawn → touch → terminate teardown calls provider terminate" do
    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    assert Process.alive?(pid)
    assert {:ok, _} = ExAtlas.Orchestrator.info(compute.id)
    :ok = ExAtlas.Orchestrator.touch(compute.id)

    ref = Process.monitor(pid)
    :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    # Upstream terminate was called
    {:ok, gone} = ExAtlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "idle timeout triggers termination" do
    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:")

    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 10,
        heartbeat_ms: 10
      )

    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    {:ok, gone} = ExAtlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "touch resets the idle timer" do
    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 200,
        heartbeat_ms: 50
      )

    _ref = Process.monitor(pid)

    # Keep touching faster than the idle ttl — server must stay alive
    Enum.each(1..4, fn _ ->
      Process.sleep(50)
      :ok = ExAtlas.Orchestrator.touch(compute.id)
    end)

    assert Process.alive?(pid)

    # Now stop touching — should die
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  describe "upstream status polling" do
    setup do
      # Idle TTL and heartbeat are pushed far out so nothing but the status
      # poller can end these sessions.
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30
      ]

      {:ok, base: base}
    end

    test "an upstream failure ends the session and reports the real cause", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.set_status(id, :failed)

      assert_receive {:atlas_compute, ^id, {:status, :failed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a pod that vanished upstream is not deleted again", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :vanished}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # Nothing left to terminate, so no doomed DELETE and no failure event.
      refute_received {:atlas_compute, ^id, {:terminate_failed, _}}
      assert_received {:atlas_compute, ^id, {:status, :terminated}}
    end

    test "a preempted spot pod is reported as preempted", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base ++ [spot: true])
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :preempted}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "upstream status changes are broadcast while the pod is alive", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id

      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      :ok = Mock.set_status(id, :running)
      assert_receive {:atlas_compute, ^id, {:status, :running}}, 2_000

      assert {:ok, %{compute: %{status: :running}}} = ExAtlas.Orchestrator.info(id)
    end

    test "a resource the provider reports as terminated is not deleted again" do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # A provider that keeps terminated records still answers the poll with
      # the resource present — and refuses to delete it a second time.
      FaultyProvider.arm(:terminate, {:error, ExAtlas.Error.new(:not_found, provider: :mock)})
      :ok = Mock.set_status(id, :terminated)

      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :normal}}, 2_000

      # The end-of-session signal `ExAtlas.Orchestrator.Events` documents is
      # `{:terminating, _}` followed by `{:status, :terminated}`. A doomed
      # DELETE replaces the second half with `{:terminate_failed, _}`.
      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      refute_received {:atlas_compute, ^id, {:terminate_failed, _}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "polling is off when :status_poll_ms is false", %{base: base} do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id

      :ok = Mock.forget(id)

      refute_receive {:atlas_compute, ^id, {:status, _}}, 300
    end
  end

  describe "on_failure: {:respawn, max_attempts}" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        spot: true,
        auth: :bearer,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30,
        on_failure: {:respawn, 1}
      ]

      {:ok, base: base}
    end

    test "a preempted pod is replaced and the session follows the new id", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:status, :preempted}}, 2_000
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      # The event carries an id, not the record: the replacement's auth handle
      # holds a live bearer token, which has no business on a PubSub topic.
      assert is_binary(new_id)
      refute new_id == old_id
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200

      # Re-keying happens before the broadcast, so the replacement — URL, token
      # and all — is readable the moment a subscriber sees the event.
      assert {:ok, %{compute: %{id: ^new_id, auth: %{token: token}}}} =
               ExAtlas.Orchestrator.info(new_id)

      assert is_binary(token)
      assert {:error, :not_tracked} = ExAtlas.Orchestrator.info(old_id)
      assert new_id in ExAtlas.Orchestrator.list_ids()
    end

    test "a preempted pod still present upstream is terminated, not abandoned", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      # A reclaimed spot pod reads as `desiredStatus: EXITED` — dead to us but
      # still present upstream, still billable, and invisible to the Reaper,
      # which only lists resources with `status: :running`. Every other respawn
      # test forgets the pod instead, which is the nil-upstream path.
      :ok = Mock.set_status(old_id, :stopped)

      assert_receive {:atlas_compute, ^old_id, {:status, :preempted}}, 2_000
      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(old_id, provider: :mock)
    end

    test "a replacement for a pod the provider forgot deletes nothing", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000
      refute_received {:atlas_compute, ^old_id, {:terminate_failed, _}}
    end

    test "the replacement is torn down with the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Mock.forget(compute.id)

      assert_receive {:atlas_compute, _, {:respawned, new_id}}, 2_000

      ref = Process.monitor(pid)
      :ok = ExAtlas.Orchestrator.stop_tracked(new_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(new_id, provider: :mock)
    end

    test "the session ends once the respawn budget is spent", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      ref = Process.monitor(pid)

      :ok = Mock.forget(compute.id)
      assert_receive {:atlas_compute, _, {:respawned, new_id}}, 2_000

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      :ok = Mock.forget(new_id)

      assert_receive {:atlas_compute, ^new_id, {:status, :preempted}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a replacement that cannot be spawned ends the session", %{base: base} do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(Keyword.put(base, :provider, FaultyProvider))

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      error = ExAtlas.Error.new(:provider, provider: :mock, message: "no capacity")
      FaultyProvider.arm(:spawn_compute, {:error, error})
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:respawn_failed, {:preempted, ^error}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # A failed respawn must not leave a half-rented session behind.
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a crashed tracker is not restarted onto the resource it replaced", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      # A restart replays the original `{compute, opts}` — the id that was
      # already replaced, and `respawns: 0`, so the budget resets and the
      # tracker polls a resource that no longer exists.
      _ = :sys.get_state(Process.whereis(ComputeSupervisor))

      assert %{active: 0} = DynamicSupervisor.count_children(ComputeSupervisor)
      assert {:error, :not_tracked} = ExAtlas.Orchestrator.info(old_id)
    end

    test "a crash-looping image is not respawned", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # An image that failed on this host will fail on the next one too, so
      # there is nothing to recover by renting more capacity.
      :ok = Mock.set_status(id, :failed)

      assert_receive {:atlas_compute, ^id, {:status, :failed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "without on_failure a preempted pod just ends the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.delete(base, :on_failure))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end
  end

  describe "upstream status polling when the provider API is failing" do
    setup do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/pods", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, ~s({"id": "pod_1", "desiredStatus": "RUNNING"}))
      end)

      Bypass.stub(bypass, "DELETE", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      opts = [
        provider: :runpod,
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        req_options: [retry: false],
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30
      ]

      {:ok, bypass: bypass, opts: opts}
    end

    test "a failing provider is reported but never ends the session", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.stub(bypass, "GET", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error": "boom"}))
      end)

      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(opts)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:poll_failed, %ExAtlas.Error{status: 500}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:poll_failed, %ExAtlas.Error{status: 500}}}, 2_000

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    end

    test "polls back off while the provider keeps failing", %{bypass: bypass, opts: opts} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/pods/pod_1", fn conn ->
        send(test_pid, {:polled, System.monotonic_time(:millisecond)})
        Plug.Conn.resp(conn, 500, ~s({"error": "boom"}))
      end)

      {:ok, _pid, _compute} = ExAtlas.Orchestrator.spawn(opts)

      assert_receive {:polled, first}, 2_000
      assert_receive {:polled, second}, 2_000
      assert_receive {:polled, third}, 2_000

      # 30ms base doubling per failure: the third gap must exceed the first.
      assert third - second > second - first
    end
  end

  describe "option validation" do
    test "a non-positive :status_poll_ms is refused before anything is rented" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 status_poll_ms: 0
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a stringly-typed :status_poll_ms is refused" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 status_poll_ms: "30000"
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "`on_failure: :respawn` — the plausible typo — is refused" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 on_failure: :respawn
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a tracker that cannot start takes its resource down with it" do
      stop_supervised!(ComputeSupervisor)

      start_supervised!(
        {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one, max_children: 0}
      )

      assert {:error, {:tracker_start_failed, :max_children}} =
               ExAtlas.Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x")

      # Nothing tracks it, so it must not survive the failure.
      assert {:ok, [%{status: :terminated}]} = ExAtlas.list_compute(provider: :mock)
    end
  end

  # Hold a poll open, then assert the tracker still answers. The alternative —
  # a poll done inline in the callback — parks the mailbox for as long as the
  # provider takes (up to ~120s of Req retries).
  defp block_a_poll(base) do
    {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
    FaultyProvider.arm(:get_compute, {:block, self()})
    assert_receive {:blocked, :get_compute, _task}, 2_000
    {pid, compute}
  end

  describe "a poll that blows up" do
    setup do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, base: base}
    end

    test "a raise is reported like any other failed poll", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # `Client.fetch_key!/1` raises on a key that resolves to nil, and a
      # malformed body can still raise in a translator. Neither is evidence
      # that the resource died — but a raise in the callback would run
      # `terminate/2` and DELETE it.
      FaultyProvider.arm(:get_compute, :raise)

      assert_receive {:atlas_compute, ^id, {:poll_failed, _reason}}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a stray message cannot end the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))
      ref = Process.monitor(pid)

      send(pid, :a_message_from_somewhere_else)

      # The call is handled after the stray message, so a reply proves the
      # server survived it.
      assert {:ok, _} = ExAtlas.Orchestrator.info(compute.id)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "a poll the provider never answers" do
    setup do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, base: base}
    end

    test "does not delay teardown, so the resource is still deleted", %{base: base} do
      {pid, compute} = block_a_poll(base)

      ref = Process.monitor(pid)
      :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "does not delay info/1 or touch/1", %{base: base} do
      {_pid, compute} = block_a_poll(base)

      assert {:ok, before} = ExAtlas.Orchestrator.info(compute.id)
      assert :ok = ExAtlas.Orchestrator.touch(compute.id)
      assert {:ok, touched} = ExAtlas.Orchestrator.info(compute.id)
      assert touched.last_activity_ms >= before.last_activity_ms
    end
  end

  describe "task mode" do
    setup do
      # Idle TTL and heartbeat are set aggressively short on purpose: task mode
      # must ignore both, and an interactive server with these numbers would be
      # dead within a few tens of milliseconds.
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        idle_ttl_ms: 10,
        heartbeat_ms: 10,
        status_poll_ms: 10,
        max_runtime_ms: 60_000
      ]

      {:ok, base: base}
    end

    defp start_task(base, overrides \\ []) do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.merge(base, overrides))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute}
    end

    test "the idle clock never runs — an unattended task outlives its idle ttl", %{base: base} do
      {pid, compute} = start_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:heartbeat, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "touch/1 is meaningless but harmless in task mode", %{base: base} do
      {_pid, compute} = start_task(base)

      assert :ok = ExAtlas.Orchestrator.touch(compute.id)
      assert {:ok, %{mode: :task}} = ExAtlas.Orchestrator.info(compute.id)
    end

    test "a self-terminated container completes, and nothing is deleted twice", %{base: base} do
      {pid, compute} = start_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      # The self-termination wrapper DELETEs the pod from inside the container,
      # so the next poll 404s. That 404 is the only container-exit signal
      # RunPod's REST API can produce.
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, first}, 2_000
      assert_receive {:atlas_compute, ^id, second}, 2_000
      assert_receive {:atlas_compute, ^id, third}, 2_000
      assert_receive {:atlas_compute, ^id, fourth}, 2_000

      # The task outcome precedes the end-of-session pair, so a subscriber that
      # ignores {:task, _} still sees a correct lifecycle.
      assert [
               {:status, :vanished},
               {:task, :completed},
               {:terminating, _},
               {:status, :terminated}
             ] =
               [first, second, third, fourth]

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a container that never self-terminated is killed at the deadline", %{base: base} do
      # Covers both the crash-before-the-cleanup-line case and a hung process:
      # the pod stays desiredStatus RUNNING forever, so no observation will ever
      # end this task and only the wall clock can.
      {pid, compute} = start_task(base, max_runtime_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:task, :completed}}, 0
      assert_receive {:atlas_compute, ^id, {:task, :timed_out}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # The meter is actually stopped, not just the tracker.
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a resource that never leaves provisioning fails as :never_ready", %{base: base} do
      {pid, compute} = start_task(base, ready_timeout_ms: 300)
      id = compute.id
      ref = Process.monitor(pid)

      # An image that will not pull: the pod is rented and billing, but no
      # container ever starts.
      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      assert_receive {:atlas_compute, ^id, {:task, {:failed, :never_ready}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a task that did become ready is never failed as :never_ready", %{base: base} do
      {pid, compute} = start_task(base, ready_timeout_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:task, _}}, 300
      refute_received {:DOWN, ^ref, :process, ^pid, _}
    end

    test "a failed poll ends nothing — the task keeps running", %{base: base} do
      {pid, compute} =
        start_task(base, provider: FaultyProvider, status_poll_ms: 10)

      id = compute.id
      ref = Process.monitor(pid)

      FaultyProvider.arm(
        :get_compute,
        {:error, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert_receive {:atlas_compute, ^id, {:poll_failed, _}}, 2_000
      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a preempted spot task with no respawn budget reports the cause", %{base: base} do
      {pid, compute} = start_task(base, spot: true)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, :preempted}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "the deadline is wall clock from spawn and carries across a respawn", %{base: base} do
      # A caller who asked for 90 minutes must not be able to spend 360 by
      # being preempted three times, so the replacement inherits what is left
      # of the original budget rather than starting a fresh one.
      {_pid, compute} = start_task(base, spot: true, on_failure: {:respawn, 1})
      id = compute.id

      assert {:ok, %{max_runtime_remaining_ms: before_ms}} = ExAtlas.Orchestrator.info(id)

      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000

      assert {:ok, %{max_runtime_remaining_ms: after_ms}} = ExAtlas.Orchestrator.info(new_id)

      # A re-armed deadline would have jumped back up to the full budget.
      assert after_ms < before_ms
    end

    test "an interactive session gets no task events at all" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: 10
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :vanished}}, 2_000
      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end
  end

  describe "task option validation" do
    test "rejects a bad mode before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x", mode: :batch)

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "rejects a bad max_runtime_ms or ready_timeout_ms before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 mode: :task,
                 max_runtime_ms: 0
               )

      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 mode: :task,
                 ready_timeout_ms: "10s"
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end
  end

  describe "run_task/1" do
    test "runs a command to completion and reports the outcome" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :mock,
          gpu: :h100,
          image: "ghcr.io/acme/trainer:latest",
          command: ["/app/train.sh"],
          name: "atlas-task-42",
          status_poll_ms: 10,
          max_runtime_ms: 60_000
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      assert {:ok, %{mode: :task}} = ExAtlas.Orchestrator.info(id)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "always has a deadline, even when the caller forgets to ask for one" do
      # An unattended task with no wall-clock cap is the billing trap this
      # whole feature exists to close, so the wrapper supplies one.
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :mock,
          gpu: :h100,
          image: "x",
          command: ["/app/train.sh"],
          status_poll_ms: false
        )

      assert {:ok, info} = ExAtlas.Orchestrator.info(compute.id)
      assert is_integer(info.max_runtime_remaining_ms)
      assert info.max_runtime_remaining_ms > 0
    end

    test "validates its options before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.run_task(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 max_runtime_ms: -1
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end
  end

  describe "pod callbacks" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10,
        max_runtime_ms: 60_000,
        callback: "https://app.example.com/atlas/cb"
      ]

      {:ok, base: base}
    end

    defp start_reporting_task(base, overrides \\ []) do
      opts = Keyword.merge(base, overrides)
      {:ok, prepared} = Callback.prepare(opts)
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(prepared)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute, prepared[:callback].task_id}
    end

    test "a progress report reaches subscribers on the compute topic", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      assert :ok = Callback.ingest(task_id, :progress, %{"seq" => 1, "pct" => 42})

      assert_receive {:atlas_compute, ^id, {:progress, %{"pct" => 42}}}, 2_000
    end

    test "a log batch reaches subscribers and is retained nowhere", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      assert :ok = Callback.ingest(task_id, :log, %{"lines" => ["epoch 1", "epoch 2"]})

      assert_receive {:atlas_compute, ^id, {:log, %{"lines" => ["epoch 1", "epoch 2"]}}}, 2_000

      # Nothing about the tracked state grew: the boundary is a bus, not a store.
      assert {:ok, info} = ExAtlas.Orchestrator.info(id)
      refute Map.has_key?(info, :logs)
    end

    test "progress does not postpone the idle clock", %{base: base} do
      # An authenticated but compromised pod must not be able to keep itself
      # alive against the idle TTL just by talking.
      {_pid, compute, task_id} = start_reporting_task(base, mode: :interactive)
      id = compute.id
      {:ok, %{last_activity_ms: before}} = ExAtlas.Orchestrator.info(id)

      :ok = Callback.ingest(task_id, :progress, %{"pct" => 1})
      assert_receive {:atlas_compute, ^id, {:progress, _}}, 2_000

      assert {:ok, %{last_activity_ms: ^before}} = ExAtlas.Orchestrator.info(id)
    end

    test "a finish report is announced the moment it lands", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
    end

    test "a clean exit followed by the pod vanishing completes, provably", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a non-zero exit fails the task with the code the container reported", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 3})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 3}}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, {:exit_code, 3}}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a report from a pod that never vanishes finishes on the grace timer", %{base: base} do
      # self_terminate: false, a skipped trap, a DELETE that failed. Today this
      # can only ever end as :timed_out, an hour later.
      {pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # And the meter is actually stopped — terminate/2 issued the DELETE the
      # container's own trap evidently did not.
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "the grace window waits for the 404 rather than pre-empting it", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 60_000)
      id = compute.id

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000

      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
    end

    test "a second finish report does not restart the grace window", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 80)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 9})

      # First report wins: a replayed or retried finish cannot rewrite the
      # outcome, and cannot buy the pod another grace window either.
      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "the deadline stays authoritative when nothing ever calls back", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base, max_runtime_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:task, :timed_out}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a configured callback nobody uses behaves exactly like no callback", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a callback for a task that is not this one is ignored", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      assert {:error, :not_tracked} =
               Callback.ingest("some-other-task", :finish, %{"exit_code" => 1})

      refute_receive {:atlas_compute, ^id, {:task_report, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
    end
  end

  describe "callbacks and spot capacity" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        spot: true,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10,
        max_runtime_ms: 60_000,
        on_failure: {:respawn, 1},
        callback: "https://app.example.com/atlas/cb"
      ]

      {:ok, base: base}
    end

    test "a task that reported finish is never respawned", %{base: base} do
      # The ambiguity #25 exists to kill: on spot capacity a 404 means both
      # "self-terminated fine" and "reclaimed", so respawn can re-run finished
      # work. A recorded report settles it.
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end

    test "a genuine preemption with no report still respawns", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      old_id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    end

    test "the task id follows the replacement, so a respawned pod can still report",
         %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      # The credential in the replacement's env is the same one: it is bound to
      # the task, not to a compute id that no longer exists.
      assert :ok = Callback.ingest(task_id, :progress, %{"pct" => 50})

      assert_receive {:atlas_compute, ^new_id, {:progress, %{"pct" => 50}}}, 2_000
    end
  end
end
