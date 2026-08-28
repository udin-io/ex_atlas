defmodule ExAtlas.Orchestrator.ComputeServerTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.{ComputeRegistry, ComputeSupervisor, Events}
  alias ExAtlas.Providers.Mock

  setup do
    Application.put_env(:ex_atlas, :start_orchestrator, true)
    Application.put_env(:ex_atlas, :default_provider, :mock)
    Mock.reset()

    start_supervised!({Registry, keys: :unique, name: ComputeRegistry})
    start_supervised!({DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one})

    if Code.ensure_loaded?(Phoenix.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ExAtlas.PubSub})
    end

    on_exit(fn ->
      Application.delete_env(:ex_atlas, :start_orchestrator)
      Application.delete_env(:ex_atlas, :default_provider)
    end)

    :ok
  end

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

    test "polling is off when :status_poll_ms is false", %{base: base} do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id

      :ok = Mock.forget(id)

      refute_receive {:atlas_compute, ^id, {:status, _}}, 300
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
end
