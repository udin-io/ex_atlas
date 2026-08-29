defmodule ExAtlas.Orchestrator.UpstreamStatusTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Providers.Mock

  doctest ExAtlas.Orchestrator.UpstreamStatus

  describe "observe/2 against a provider that answers" do
    setup do
      Mock.reset()
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, id: compute.id, opts: [provider: :mock]}
    end

    test "a running resource is alive", %{id: id, opts: opts} do
      assert {:alive, %{id: ^id, status: :running}} = UpstreamStatus.observe(id, opts)
    end

    test "a provisioning resource is still alive", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :provisioning)
      assert {:alive, %{status: :provisioning}} = UpstreamStatus.observe(id, opts)
    end

    test "a failed resource is dead with the reason :failed", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :failed)
      assert {:dead, :failed, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end

    test "a stopped resource is dead with the reason :stopped", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :stopped)
      assert {:dead, :stopped, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end

    test "a terminated resource is dead with the reason :terminated", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :terminated)
      assert {:dead, :terminated, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end

    test "a vanished resource is dead with no compute to report", %{id: id, opts: opts} do
      :ok = Mock.forget(id)
      assert {:dead, :vanished, nil} = UpstreamStatus.observe(id, opts)
    end
  end

  describe "observe/2 for a spot resource" do
    setup do
      Mock.reset()
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", spot: true)
      {:ok, id: compute.id, opts: [provider: :mock, spot: true]}
    end

    test "vanishing reads as preemption", %{id: id, opts: opts} do
      :ok = Mock.forget(id)
      assert {:dead, :preempted, nil} = UpstreamStatus.observe(id, opts)
    end

    test "stopping reads as preemption", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :stopped)
      assert {:dead, :preempted, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end

    test "being terminated reads as preemption", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :terminated)
      assert {:dead, :preempted, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end

    test "a crashed image is still :failed, not preemption", %{id: id, opts: opts} do
      :ok = Mock.set_status(id, :failed)
      assert {:dead, :failed, %{id: ^id}} = UpstreamStatus.observe(id, opts)
    end
  end

  describe "observe/2 when the upstream API misbehaves" do
    setup do
      bypass = Bypass.open()

      opts = [
        provider: :runpod,
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        req_options: [retry: false]
      ]

      {:ok, bypass: bypass, opts: opts}
    end

    test "a 404 is a vanished resource", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/pods/pod_1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(404, ~s({"error": "pod not found"}))
      end)

      assert {:dead, :vanished, nil} = UpstreamStatus.observe("pod_1", opts)
    end

    test "a 500 leaves the resource's fate unknown", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error": "boom"}))
      end)

      assert {:poll_failed, %ExAtlas.Error{status: 500}} = UpstreamStatus.observe("pod_1", opts)
    end

    test "a 429 leaves the resource's fate unknown", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 429, ~s({"error": "slow down"}))
      end)

      assert {:poll_failed, %ExAtlas.Error{kind: :rate_limited}} =
               UpstreamStatus.observe("pod_1", opts)
    end

    test "an unreachable API leaves the resource's fate unknown", %{bypass: bypass, opts: opts} do
      Bypass.down(bypass)

      assert {:poll_failed, %ExAtlas.Error{kind: :transport}} =
               UpstreamStatus.observe("pod_1", opts)
    end

    test "a malformed body leaves the resource's fate unknown", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/pods/pod_1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, "null")
      end)

      assert {:poll_failed, %ExAtlas.Error{kind: :provider}} =
               UpstreamStatus.observe("pod_1", opts)
    end

    test "a bad API key leaves the resource alone rather than declaring it dead", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect(bypass, "GET", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 401, ~s({"error": "bad key"}))
      end)

      assert {:poll_failed, %ExAtlas.Error{kind: :unauthorized}} =
               UpstreamStatus.observe("pod_1", opts)
    end
  end

  describe "next_interval_ms/3" do
    test "stays around the base interval while polls succeed" do
      intervals = for _ <- 1..50, do: UpstreamStatus.next_interval_ms(1_000, 0)

      assert Enum.all?(intervals, &(&1 >= 900 and &1 <= 1_100))
    end

    test "jitters so a fleet of pollers does not sync up" do
      intervals = for _ <- 1..50, do: UpstreamStatus.next_interval_ms(1_000, 0)

      assert intervals |> Enum.uniq() |> length() > 1
    end

    test "backs off exponentially as consecutive failures accumulate" do
      assert UpstreamStatus.next_interval_ms(1_000, 1, jitter: 0.0) == 2_000
      assert UpstreamStatus.next_interval_ms(1_000, 2, jitter: 0.0) == 4_000
      assert UpstreamStatus.next_interval_ms(1_000, 3, jitter: 0.0) == 8_000
    end

    test "caps the backoff so a long outage does not stall polling forever" do
      assert UpstreamStatus.next_interval_ms(1_000, 40, jitter: 0.0, max_ms: 30_000) == 30_000
    end

    test "never returns a non-positive interval" do
      assert UpstreamStatus.next_interval_ms(1, 0) > 0
    end
  end
end
