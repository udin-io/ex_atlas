defmodule ExAtlas.Orchestrator.AdopterTest do
  @moduledoc """
  Boot-time re-adoption: the deploy scenario the whole feature exists for.

  Each test kills a tracker without letting it run `terminate/2` — a brutal
  kill, exactly like the VM going away under a deploy — which leaves the pod
  running upstream and its record on the store, and then runs the Adopter over
  what is left.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Events, TrackingStore}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.TrackingStore.Memory

  setup do
    ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
  end

  defp task_opts(overrides) do
    Keyword.merge(
      [
        provider: :mock,
        gpu: :h100,
        image: "trainer:latest",
        name: "atlas-adoptable",
        mode: :task,
        max_runtime_ms: 90 * 60 * 1_000,
        status_poll_ms: false,
        persist: true
      ],
      overrides
    )
  end

  # Spawn a persisted task, then take the node out from under it. The pod keeps
  # running and billing; the record is all that is left of it.
  defp orphaned_task(overrides \\ []) do
    {:ok, pid, compute} = Orchestrator.spawn(task_opts(overrides))

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

    # The Registry unregisters on its own DOWN, which it processes in its own
    # mailbox. Synchronize with it so "not tracked" is settled before the test
    # asserts anything about it.
    _ = :sys.get_state(ExAtlas.Orchestrator.ComputeRegistry)

    compute
  end

  defp backdate!(id, ago_ms) do
    {:ok, record} = Memory.get(id)
    :ok = Memory.put(%{record | spawned_at_ms: record.spawned_at_ms - ago_ms})
    record
  end

  describe "a task still running upstream" do
    test "comes back under a tracker instead of being left to bill" do
      compute = orphaned_task()
      assert {:error, :not_tracked} = Orchestrator.info(compute.id)

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert {:ok, %{compute: %{id: id}, mode: :task}} = Orchestrator.info(compute.id)
      assert id == compute.id
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "keeps its record, so the Reaper still recognises it as ours" do
      compute = orphaned_task()

      :ok = Adopter.run(notify: self())

      assert {:ok, %{id: id}} = Memory.get(compute.id)
      assert id == compute.id
    end

    test "re-registers its callback id, so in-flight pod callbacks stop 410-ing" do
      compute = orphaned_task(callback: "https://app.example.com/atlas/cb")
      {:ok, %{callback_task_id: task_id}} = Memory.get(compute.id)

      assert {:error, :not_tracked} = ExAtlas.Callback.ingest(task_id, :progress, %{"step" => 1})

      :ok = Adopter.run(notify: self())

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      assert :ok = ExAtlas.Callback.ingest(task_id, :progress, %{"step" => 2})

      id = compute.id
      assert_receive {:atlas_compute, ^id, {:progress, %{"step" => 2}}}, 2_000
    end
  end

  describe "the carried deadline" do
    test "a budget already spent while the node was down fires immediately" do
      compute = orphaned_task()
      # 90-minute task, two hours of wall clock gone. There is nothing left to
      # spend, and the worst possible outcome is a silent fresh 90 minutes.
      backdate!(compute.id, 2 * 60 * 60 * 1_000)

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Adopter.run(notify: self())

      id = compute.id
      assert_receive {:atlas_compute, ^id, {:task, :timed_out}}, 2_000
      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a partly spent budget resumes with what is left, not a fresh one" do
      compute = orphaned_task()
      backdate!(compute.id, 30 * 60 * 1_000)

      :ok = Adopter.run(notify: self())

      assert {:ok, %{max_runtime_remaining_ms: remaining}} = Orchestrator.info(compute.id)

      # ~60 minutes left of the original 90. Anything near 90 means the
      # deadline was re-armed from scratch, which is how a 90-minute task
      # quietly becomes a several-hour bill.
      assert remaining > 55 * 60 * 1_000
      assert remaining < 65 * 60 * 1_000
    end
  end

  describe "reconciling against the provider" do
    test "a task that died while the node was down ends through the normal path" do
      compute = orphaned_task(status_poll_ms: 30)
      :ok = Mock.set_status(compute.id, :failed)

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Adopter.run(notify: self())

      # Adopted, then the tracker's own first poll classifies the death — one
      # death-classification path, not a second copy inside the Adopter.
      id = compute.id
      assert_receive {:atlas_compute, ^id, {:status, :failed}}, 2_000
      assert_receive {:atlas_compute, ^id, {:task, {:failed, :failed}}}, 2_000
      assert :error = Memory.get(id)
    end

    test "a vanished pod is forgotten and never gets a tracker" do
      compute = orphaned_task()
      :ok = Mock.forget(compute.id)

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      # Nothing to adopt and nothing to bill, so the record is the only thing
      # left to clean up. Starting a tracker would broadcast a death nobody is
      # listening for.
      assert :error = Memory.get(compute.id)
      assert Orchestrator.list_ids() == []
    end
  end

  describe "a store that cannot account for itself" do
    test "adopts nothing and reports the failure" do
      compute = orphaned_task()
      Memory.fail_all(:simulated_corruption)

      :ok = Adopter.run(notify: self())

      assert_receive :adoption_failed, 2_000
      refute_received :adoption_complete
      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
    end
  end

  describe "records this build does not understand" do
    test "are left alone rather than adopted or deleted" do
      compute = orphaned_task()
      {:ok, record} = Memory.get(compute.id)
      :ok = Memory.put(%{record | v: TrackingStore.version() + 1})

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      # No tracker: we cannot know what the fields mean. But the record stays,
      # because deleting it is what lets the Reaper delete a live pod that a
      # newer build of this same app rented.
      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
      assert {:ok, _record} = Memory.get(compute.id)
    end
  end

  describe "an empty store" do
    test "settles immediately so the Reaper is not blocked" do
      assert :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
    end
  end
end
