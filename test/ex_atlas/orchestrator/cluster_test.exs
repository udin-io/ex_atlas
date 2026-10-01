defmodule ExAtlas.Orchestrator.ClusterTest do
  # Starts a real second node. While it runs, `Node.list/0` is non-empty for
  # every test on this node, so this module must never run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias ExAtlas.Orchestrator.Reaper
  alias ExAtlas.Test.{Cluster, RemoteProvider}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
    {peer, node_b} = Cluster.start_peer!()
    {:ok, peer: peer, node_b: node_b}
  end

  describe "two nodes with owners, one account" do
    setup %{node_b: node_b} do
      TestOrchestrator.put_env(reap_owner: "a")

      Cluster.put_orchestrator_env(node_b,
        reap_owner: "b",
        reap_grace_ms: 0,
        tracking_store: false
      )
    end

    test "node B's reap cycle leaves node A's tracked pod running", %{node_b: node_b} do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          name: "atlas-train-1",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: false
        )

      :ok = :erpc.call(node_b, Reaper, :reap_now, ["atlas-", [RemoteProvider]])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "node B still reclaims its own untracked pod", %{node_b: node_b} do
      {:ok, compute} =
        ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", name: "atlas-b-train-1")

      :ok = :erpc.call(node_b, Reaper, :reap_now, ["atlas-", [RemoteProvider]])

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "a clustered node with no owner" do
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

    test "reaps nothing, not even an untracked pod, and logs one error", %{reaper: reaper} do
      {:ok, compute} = spawn_untracked()

      log =
        capture_log(fn ->
          :ok = tick(reaper)
          :ok = tick(reaper)
        end)

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert [_once] = Regex.scan(~r/\[error\].*has no :reap_owner/, log)
    end

    test "reclaims that pod once the peer has stopped",
         %{reaper: reaper, peer: peer, node_b: node_b} do
      {:ok, compute} = spawn_untracked()
      :ok = Cluster.stop_peer!(peer, node_b)

      :ok = tick(reaper)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  defp spawn_untracked,
    do: ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", name: "atlas-orphan")

  defp tick(reaper) do
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end
end
