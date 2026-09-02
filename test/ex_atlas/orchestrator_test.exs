defmodule ExAtlas.OrchestratorTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.Events
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Spec
  alias ExAtlas.Test.FaultyProvider

  setup do: ExAtlas.Test.Orchestrator.start!()

  describe "await_ready/2" do
    setup do
      # Idle TTL and heartbeat are pushed far out so nothing but the status
      # poller can move these sessions.
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, base: base}
    end

    test "resolves straight away when the tracked resource is already running", %{base: base} do
      {:ok, _pid, compute} = Orchestrator.spawn(base)
      id = compute.id

      # Too short to survive even one status poll, so anything that waited for
      # the next broadcast instead of reading what the tracker already knows
      # would fail here.
      assert {:ok, %Spec.Compute{id: ^id, status: :running}} =
               Orchestrator.await_ready(id, timeout_ms: 20)
    end

    test "resolves off the tracker's existing status poll", %{base: base} do
      id = tracked_provisioning(base)

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 5_000) end)
      :ok = Mock.set_status(id, :running)

      assert {:ok, %Spec.Compute{id: ^id, status: :running}} = Task.await(task, 5_000)
    end

    test "a failed poll does not resolve the wait", %{base: base} do
      id = tracked_provisioning(Keyword.put(base, :provider, FaultyProvider))

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 5_000) end)

      # The tracker broadcasts `{:poll_failed, _}` and keeps going; so must the
      # wait. Ending it here would report a provider hiccup as a pod that never
      # came up.
      FaultyProvider.arm(
        :get_compute,
        {:error, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert_receive {:atlas_compute, ^id, {:poll_failed, _}}, 2_000

      FaultyProvider.reset()
      :ok = Mock.set_status(id, :running)

      assert {:ok, %Spec.Compute{id: ^id, status: :running}} = Task.await(task, 5_000)
    end

    test "a resource that dies while waiting is reported with its cause", %{base: base} do
      id = tracked_provisioning(base)

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 5_000) end)
      :ok = Mock.set_status(id, :failed)

      assert {:error, {:dead, :failed, %Spec.Compute{id: ^id}}} = Task.await(task, 5_000)
    end

    test "gives up at the timeout without terminating anything", %{base: base} do
      id = tracked_provisioning(base)

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 40) end)

      assert {:error, {:timeout, %Spec.Compute{id: ^id, status: :provisioning}}} =
               Task.await(task, 5_000)

      assert {:ok, _} = Orchestrator.info(id)

      assert {:ok, %Spec.Compute{status: :provisioning}} =
               ExAtlas.get_compute(id, provider: :mock)
    end

    test "follows a respawn and resolves on the replacement", %{base: base} do
      # A preempted resource is replaced, not ended: the session the caller is
      # waiting on continues under a new id, and it continues on the same
      # deadline rather than buying itself a fresh one.
      id = tracked_provisioning(base ++ [spot: true, on_failure: {:respawn, 1}])

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 5_000) end)
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert {:ok, %Spec.Compute{id: ^new_id, status: :running}} = Task.await(task, 5_000)
    end

    test "the wait ends when the tracker itself goes away", %{base: base} do
      id = tracked_provisioning(base)

      task = Task.async(fn -> Orchestrator.await_ready(id, timeout_ms: 5_000) end)
      :ok = Orchestrator.stop_tracked(id)

      assert {:error, {:dead, :terminated, _}} = Task.await(task, 5_000)
    end

    test "an untracked id falls back to polling the provider" do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      id = compute.id

      assert {:ok, %Spec.Compute{id: ^id, status: :running}} =
               Orchestrator.await_ready(id, provider: :mock, timeout_ms: 500)
    end

    test "with upstream polling switched off there is nothing to observe", %{base: base} do
      # `status_poll_ms: false` says "do not watch upstream". The wait honours
      # that rather than opening the poll the caller declined, so it can only
      # report what the tracker already knows.
      {:ok, _pid, compute} = Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))
      id = compute.id
      :ok = Mock.set_status(id, :provisioning)

      assert {:ok, %Spec.Compute{status: :running}} = Orchestrator.await_ready(id, timeout_ms: 40)
    end

    defp tracked_provisioning(base) do
      {:ok, _pid, compute} = Orchestrator.spawn(base)
      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      # The Mock spawns a resource already running; a real cloud does not. Push
      # it back to provisioning and wait for the tracker to notice, so the wait
      # under test starts from where a real spawn starts.
      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      id
    end
  end
end
