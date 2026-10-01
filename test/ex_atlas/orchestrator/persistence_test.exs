defmodule ExAtlas.Orchestrator.PersistenceTest do
  @moduledoc """
  What `persist: true` writes, and what it must never write.

  The tracker lifecycle owns the record after `spawn/1` creates it: a respawn
  rewrites it, a landed report is recorded in it, and teardown removes it. Get
  any of those wrong and the next boot either adopts a pod that no longer
  exists or refills a budget that was already spent.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{ComputeSupervisor, Events, TrackingStore}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.TrackingStore.Memory

  @api_key "sk-do-not-write-me-to-disk"

  defp task_opts(overrides \\ []) do
    Keyword.merge(
      [
        provider: :mock,
        gpu: :h100,
        image: "trainer:latest",
        name: "atlas-persisted",
        mode: :task,
        max_runtime_ms: 90 * 60 * 1_000,
        status_poll_ms: false,
        persist: true
      ],
      overrides
    )
  end

  describe "persist: true" do
    setup do
      ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
    end

    test "writes a record holding what it takes to rebuild the tracker" do
      {:ok, _pid, compute} = Orchestrator.spawn(task_opts())

      assert {:ok, record} = Memory.get(compute.id)

      assert %{
               v: 1,
               id: id,
               provider: :mock,
               mode: :task,
               max_runtime_ms: 5_400_000,
               respawns: 0,
               report: nil
             } = record

      assert id == compute.id

      # Wall clock, not monotonic: the deadline has to be reconstructible in a
      # VM that has not started yet.
      assert_in_delta record.spawned_at_ms, System.system_time(:millisecond), 5_000
    end

    test "records the callback task id so in-flight pod callbacks survive" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(task_opts(callback: "https://app.example.com/atlas/cb"))

      assert {:ok, %{callback_task_id: task_id}} = Memory.get(compute.id)
      assert is_binary(task_id)
    end

    test "stop_tracked/1 deletes the pod and removes the record" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts())
      ref = Process.monitor(pid)

      :ok = Orchestrator.stop_tracked(compute.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert :error = Memory.get(compute.id)
    end

    test "reaching :max_runtime_ms deletes the pod and removes the record" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts(max_runtime_ms: 50))
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert :error = Memory.get(compute.id)
    end

    test "a landed report is recorded, so a restart cannot re-run finished work" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(callback: "https://app.example.com/atlas/cb", finish_grace_ms: 60_000)
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {:ok, %{callback_task_id: task_id}} = Memory.get(compute.id)

      :ok = ExAtlas.Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      id = compute.id
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000

      assert {:ok, %{report: %{exit_code: 0}}} = Memory.get(compute.id)
    end

    test "a respawn rewrites the record without refilling the budget" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            spot: true,
            status_poll_ms: 30,
            on_failure: {:respawn, 1}
          )
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id
      {:ok, original} = Memory.get(old_id)

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      # The replacement is what the next boot must adopt...
      assert {:ok, replacement} = Memory.get(new_id)
      assert replacement.id == new_id
      assert replacement.respawns == 1

      # ...on the original deadline. A record that re-anchored here would hand
      # a preempted 90-minute task another 90 minutes on every replacement.
      assert replacement.spawned_at_ms == original.spawned_at_ms

      # ...and the pod that is gone must not be adopted at all.
      assert :error = Memory.get(old_id)
    end
  end

  # `DynamicSupervisor.terminate_child/2` delivers `:shutdown`, the reason a
  # graceful node stop delivers. Keeping the pod needs all three: that reason,
  # a tracking store, and no exit code reported yet. Each refusal below fails
  # exactly one of them against the keep case.
  describe "a supervisor stop" do
    setup do
      ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
    end

    test "keeps a persisted task's pod and its record" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts())

      :ok = DynamicSupervisor.terminate_child(ComputeSupervisor, pid)

      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert {:ok, %{id: id}} = Memory.get(compute.id)
      assert id == compute.id
    end

    test "deletes an unpersisted task's pod" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts(persist: false))

      :ok = DynamicSupervisor.terminate_child(ComputeSupervisor, pid)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "deletes a persisted task's pod once its container reported an exit code" do
      {:ok, pid, compute} =
        Orchestrator.spawn(
          task_opts(callback: "https://app.example.com/atlas/cb", finish_grace_ms: 60_000)
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {:ok, %{callback_task_id: task_id}} = Memory.get(compute.id)
      :ok = ExAtlas.Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      id = compute.id
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000

      :ok = DynamicSupervisor.terminate_child(ComputeSupervisor, pid)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert :error = Memory.get(compute.id)
    end

    @tag :capture_log
    test "a crash deletes a persisted task's pod and its record" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts())

      :ok = GenServer.stop(pid, :boom)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
      assert :error = Memory.get(compute.id)
    end
  end

  describe "a supervisor stop with no tracking store configured" do
    setup do
      ExAtlas.Test.Orchestrator.start!()
    end

    test "deletes a persist: true task's pod, since no boot could adopt it" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts())

      :ok = DynamicSupervisor.terminate_child(ComputeSupervisor, pid)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "opting out" do
    setup do
      ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
    end

    test "persist defaults to off and writes nothing" do
      {:ok, _pid, compute} = Orchestrator.spawn(task_opts() |> Keyword.delete(:persist))

      assert :error = Memory.get(compute.id)
      assert {:ok, []} = Memory.all()
    end

    test "persist: false writes nothing" do
      {:ok, _pid, compute} = Orchestrator.spawn(task_opts(persist: false))

      assert :error = Memory.get(compute.id)
    end

    test "an interactive session cannot opt in, and nothing is rented trying" do
      assert {:error, error} = Orchestrator.spawn(task_opts(mode: :interactive))
      assert %NimbleOptions.ValidationError{} = error

      # Rejected at the same boundary that validates every other tracking
      # option: before the provider is asked to rent anything.
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
      assert {:ok, []} = Memory.all()
    end
  end

  describe "secrets" do
    @describetag :tmp_dir

    test "never reach the store's bytes on disk", %{tmp_dir: dir} do
      ExAtlas.Test.Orchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})

      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            api_key: @api_key,
            auth: :bearer,
            req_options: [auth: {:bearer, @api_key}]
          )
        )

      bytes = File.read!(Path.join(dir, "tracked.dets"))

      # The provider credential, however it was passed in.
      refute bytes =~ @api_key

      # And the resource's own bearer token, which `ExAtlas.Auth.Token`'s
      # moduledoc promises ExAtlas never stores.
      assert is_binary(compute.auth.token)
      refute bytes =~ compute.auth.token

      # The record itself did land, so this is not passing by writing nothing.
      assert {:ok, %{id: id}} = TrackingStore.Dets.get(compute.id)
      assert id == compute.id
      assert bytes =~ compute.id
    end
  end
end
