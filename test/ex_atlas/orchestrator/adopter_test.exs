defmodule ExAtlas.Orchestrator.AdopterTest do
  @moduledoc """
  Boot-time re-adoption: the deploy scenario the whole feature exists for.

  Each test kills a tracker without letting it run `terminate/2` — a brutal
  kill, exactly like the VM going away under a deploy — which leaves the pod
  running upstream and its record on the store, and then runs the Adopter over
  what is left.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Events, TrackingStore}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
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
    TestOrchestrator.sync_registry()

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

      # `{:task, _}` goes out before `terminate/2` forgets the record, so wait
      # for the tracker itself to exit.
      await_exit(id)
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

  describe "a store that misbehaves outright" do
    test "raising from all/0 fails adoption instead of failing the boot" do
      # This runs inside the host's supervision tree during their boot. A
      # host-supplied store that blows up must cost them adoption, not their
      # application.
      assert :ok = Adopter.run(store: ExAtlas.Test.TrackingStore.Raising, notify: self())

      assert_receive :adoption_failed, 2_000
    end

    test "one unreadable record does not cost the others their trackers" do
      compute = orphaned_task()
      :ok = Memory.put(%{v: TrackingStore.version(), id: "not-a-real-record"})

      assert :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert {:ok, _info} = Orchestrator.info(compute.id)
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

  # A task spawned by the node whose `:reap_owner` is `owner`, orphaned as a
  # deploy would. The test then sets the owner of the node that boots.
  defp orphaned_task_of(owner, overrides \\ []) do
    TestOrchestrator.put_env(reap_owner: owner)
    orphaned_task(overrides)
  end

  # What a v0.7.0 node wrote: a spawned record with no owner and `v: 1`.
  defp downgrade_to_v1!(id) do
    {:ok, record} = Memory.get(id)
    :ok = Memory.put(record |> Map.delete(:owner) |> Map.put(:v, 1))
    {:ok, v1} = Memory.get(id)
    v1
  end

  defp boot_as(owner) do
    TestOrchestrator.put_env(reap_owner: owner)
    log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
    assert_receive :adoption_complete, 2_000
    log
  end

  describe "records written by a v0.7.0 node" do
    test "a node with no owner adopts an unowned v1 record and leaves it v1" do
      compute = orphaned_task_of(nil)
      v1 = downgrade_to_v1!(compute.id)

      boot_as(nil)

      assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)
      assert {:ok, ^v1} = Memory.get(compute.id)
    end
  end

  describe "a store shared by several nodes" do
    test "a node leaves another owner's live task alone and logs its id" do
      compute = orphaned_task_of("a")
      {:ok, before} = Memory.get(compute.id)

      log = boot_as("b")

      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
      assert {:ok, ^before} = Memory.get(compute.id)
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)

      assert [[line]] = Regex.scan(~r/\[info\][^\n]*owner "a"[^\n]*/, log)
      assert line =~ compute.id
    end

    test "control: the owner of that record adopts it" do
      compute = orphaned_task_of("a")

      boot_as("a")

      assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)
    end

    test "logs one line per other owner, listing every id of that owner" do
      a1 = orphaned_task_of("a", name: "atlas-one")
      a2 = orphaned_task_of("a", name: "atlas-two")
      c1 = orphaned_task_of("c", name: "atlas-three")

      log = boot_as("b")

      assert [[a_line]] = Regex.scan(~r/\[info\][^\n]*owner "a"[^\n]*/, log)
      assert a_line =~ a1.id and a_line =~ a2.id
      assert [[c_line]] = Regex.scan(~r/\[info\][^\n]*owner "c"[^\n]*/, log)
      assert c_line =~ c1.id
    end

    test "a node with no owner leaves an owned record alone" do
      compute = orphaned_task_of("a")

      boot_as(nil)

      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
      assert {:ok, %{owner: "a"}} = Memory.get(compute.id)
    end

    test "the first node to adopt an unowned v1 record claims it" do
      compute = orphaned_task_of("a")
      downgrade_to_v1!(compute.id)

      boot_as("b")

      assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)
      assert {:ok, %{v: 2, owner: "b"}} = Memory.get(compute.id)
    end

    test "a claimed record is left alone by the next owner to boot" do
      compute = orphaned_task_of("a")
      downgrade_to_v1!(compute.id)
      boot_as("b")
      {:ok, pid} = Orchestrator.lookup(compute.id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      TestOrchestrator.sync_registry()

      boot_as("c")

      assert {:error, :not_tracked} = Orchestrator.info(compute.id)
      assert {:ok, %{owner: "b"}} = Memory.get(compute.id)
    end

    test "an invalid :reap_owner adopts nothing, keeps every record and logs one error" do
      owned = orphaned_task_of("a", name: "atlas-owned")
      unowned = orphaned_task_of("a", name: "atlas-unowned")
      v1 = downgrade_to_v1!(unowned.id)
      {:ok, owned_record} = Memory.get(owned.id)

      log = boot_as("Not Valid")

      assert {:error, :not_tracked} = Orchestrator.info(owned.id)
      assert {:error, :not_tracked} = Orchestrator.info(unowned.id)
      assert {:ok, ^owned_record} = Memory.get(owned.id)
      assert {:ok, ^v1} = Memory.get(unowned.id)
      assert [_once] = Regex.scan(~r/\[error\][^\n]*:reap_owner/, log)
    end

    test "another owner's record with an odd id does not cost this node its adoption" do
      mine = orphaned_task_of("b")
      :ok = Memory.put(%{v: 2, mode: :task, owner: "a", id: {:odd, :id}})

      log = boot_as("b")

      assert {:ok, %{mode: :task}} = Orchestrator.info(mine.id)
      assert log =~ "{:odd, :id}"
    end

    test "another owner's record of a pod the provider forgot is kept" do
      compute = orphaned_task_of("a")
      :ok = Mock.forget(compute.id)

      boot_as("b")

      assert {:ok, %{owner: "a"}} = Memory.get(compute.id)
      assert Orchestrator.list_ids() == []
    end
  end

  describe "an empty store" do
    test "settles immediately so the Reaper is not blocked" do
      assert :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
    end
  end

  defp await_exit(id) do
    case Orchestrator.lookup(id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      :error ->
        :ok
    end
  end
end
