defmodule ExAtlas.Orchestrator.ClusterTest do
  # Starts a real second node. While it runs, `Node.list/0` is non-empty for
  # every test on this node, so this module must never run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @moduletag :capture_log

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Reaper}
  alias ExAtlas.Test.{Cluster, RemoteProvider}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
  alias ExAtlas.Test.TrackingStore.{Memory, Remote}

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

    test "reap_now/2 reaps nothing either", %{reaper: _reaper} do
      {:ok, compute} = spawn_untracked()

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "reclaims that pod once the peer has stopped",
         %{reaper: reaper, peer: peer, node_b: node_b} do
      {:ok, compute} = spawn_untracked()
      :ok = Cluster.stop_peer!(peer, node_b)

      :ok = tick(reaper)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "two connected nodes and this node's owner" do
    # The pod is this node's own by name, untracked, running and past grace,
    # so the peer's owner is the only thing that differs between the two tests.
    setup do
      TestOrchestrator.put_env(
        reap_owner: "a",
        tracking_store: false,
        reap_grace_ms: 0,
        reap_interval_ms: 60_000,
        reap_providers: [:mock],
        reap_name_prefix: "atlas-"
      )

      {:ok, reaper: start_supervised!(Reaper)}
    end

    test "a peer with the same owner stops reaping and logs one error",
         %{reaper: reaper, node_b: node_b} do
      Cluster.put_orchestrator_env(node_b, reap_owner: "a")
      {:ok, compute} = spawn_untracked("atlas-a-orphan")

      log =
        capture_log(fn ->
          :ok = tick(reaper)
          :ok = tick(reaper)
        end)

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert [_once] = Regex.scan(~r/\[error\].*:reap_owner "a" is also set on/, log)
      assert log =~ Atom.to_string(node_b)
    end

    # A peer that reports no owner, or cannot report one, is not a duplicate.
    for {label, peer_env} <- [
          {"no owner", [reap_owner: nil]},
          {"an invalid owner", [reap_owner: "Not Valid"]}
        ] do
      test "a peer with #{label} leaves reaping on", %{reaper: reaper, node_b: node_b} do
        Cluster.put_orchestrator_env(node_b, unquote(peer_env))
        {:ok, compute} = spawn_untracked("atlas-a-orphan")

        :ok = tick(reaper)

        assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      end
    end

    test "reap_now/2 refuses a same-owner peer too", %{node_b: node_b} do
      Cluster.put_orchestrator_env(node_b, reap_owner: "a")
      {:ok, compute} = spawn_untracked("atlas-a-orphan")

      :ok = Reaper.reap_now("atlas-", [:mock])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "a peer that cannot report its owner is warned about once, and reaping goes on",
         %{reaper: reaper, node_b: node_b} do
      :ok = Cluster.unload_ownership!(node_b)
      {:ok, compute} = spawn_untracked("atlas-a-orphan")

      log =
        capture_log(fn ->
          :ok = tick(reaper)
          :ok = tick(reaper)
        end)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert [_once] = Regex.scan(~r/\[warning\].*#{node_b} cannot report its :reap_owner/, log)
    end

    test "a peer that reports another owner is not warned about",
         %{reaper: reaper, node_b: node_b} do
      Cluster.put_orchestrator_env(node_b, reap_owner: "b")

      log = capture_log(fn -> :ok = tick(reaper) end)

      refute log =~ "cannot report its :reap_owner"
    end

    test "a peer with a different owner leaves reaping on", %{reaper: reaper, node_b: node_b} do
      Cluster.put_orchestrator_env(node_b, reap_owner: "b")
      {:ok, compute} = spawn_untracked("atlas-a-orphan")

      :ok = tick(reaper)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "two nodes, one shared tracking store, one account" do
    # Node A is this node, with `Memory` as its store. The peer's store is
    # `Remote`, which reads and writes that same `Memory`: one database.
    setup do
      TestOrchestrator.put_env(
        tracking_store: Memory,
        reap_owner: "a",
        reap_providers: [],
        reap_name_prefix: "atlas-"
      )

      start_supervised!(Memory)
      Application.put_env(:ex_atlas, :remote_provider_node, node())
      on_exit(fn -> Application.delete_env(:ex_atlas, :remote_provider_node) end)
      :ok
    end

    defp boot_b(node_b, owner) do
      Cluster.boot_orchestrator!(node_b, tracking_store: Remote, reap_owner: owner)
    end

    defp spawn_persisted(name \\ "atlas-train-42") do
      Orchestrator.run_task(
        provider: RemoteProvider,
        gpu: :h100,
        image: "trainer",
        name: name,
        persist: true,
        max_runtime_ms: 3_600_000,
        status_poll_ms: false
      )
    end

    defp kill_tracker(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      _ = :sys.get_state(ExAtlas.Orchestrator.ComputeRegistry)
      :ok
    end

    test "node B's boot starts no tracker for node A's live task", %{node_b: node_b} do
      {:ok, pid_a, compute} = spawn_persisted()

      boot_b(node_b, "b")

      assert {:error, :not_tracked} = :erpc.call(node_b, Orchestrator, :info, [compute.id])

      assert {:error, :not_tracked} =
               :erpc.call(node_b, Orchestrator, :stop_tracked, [compute.id])

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert {:ok, %{owner: "a"}} = Memory.get(compute.id)
      assert Process.alive?(pid_a)
    end

    test "control: node B adopts a record spawned as owner b", %{node_b: node_b} do
      TestOrchestrator.put_env(reap_owner: "b")
      {:ok, pid, compute} = spawn_persisted()
      kill_tracker(pid)
      TestOrchestrator.put_env(reap_owner: "a")

      boot_b(node_b, "b")

      assert {:ok, %{mode: :task}} = :erpc.call(node_b, Orchestrator, :info, [compute.id])
    end

    test "a late node A finds the task of A's own record while B tracks nothing",
         %{node_b: node_b} do
      {:ok, pid, compute} = spawn_persisted()
      kill_tracker(pid)

      boot_b(node_b, "b")
      assert {:error, :not_tracked} = :erpc.call(node_b, Orchestrator, :info, [compute.id])

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)
      assert {:error, :not_tracked} = :erpc.call(node_b, Orchestrator, :info, [compute.id])
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "a node whose owner is gone for good leaves its task to the operator",
         %{peer: peer, node_b: node_b} do
      boot_b(node_b, "b")

      {:ok, _pid, compute} =
        :erpc.call(node_b, Orchestrator, :run_task, [
          [
            provider: RemoteProvider,
            gpu: :h100,
            image: "trainer",
            name: "atlas-train-7",
            persist: true,
            max_runtime_ms: 3_600_000,
            status_poll_ms: false
          ]
        ])

      :ok = Cluster.stop_peer!(peer, node_b)

      log =
        capture_log(fn ->
          :ok = Adopter.run(notify: self())
          :ok = Reaper.reap_now("atlas-", [RemoteProvider])
        end)

      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
      assert {:ok, %{owner: "b"}} = Memory.get(compute.id)
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert [[line]] = Regex.scan(~r/\[info\][^\n]*owner "b"[^\n]*/, log)
      assert line =~ compute.id
    end
  end

  defp spawn_untracked(name \\ "atlas-orphan"),
    do: ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", name: name)

  defp tick(reaper) do
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end
end
