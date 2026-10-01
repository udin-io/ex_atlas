defmodule ExAtlas.Orchestrator.ClusterTest do
  # Starts a real second node. While it runs, `Node.list/0` is non-empty for
  # every test on this node, so this module must never run async.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ExAtlas.Orchestrator.Reaper
  alias ExAtlas.Test.{Cluster, RemoteProvider}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
    {_peer, node_b} = Cluster.start_peer!()
    {:ok, node_b: node_b}
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
end
