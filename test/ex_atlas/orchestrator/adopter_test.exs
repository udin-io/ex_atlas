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

    test "a record from before the timer bound still adopts, at the bound" do
      # The previous release accepted any positive integer: 60 days here.
      sixty_days = 60 * 24 * 60 * 60 * 1_000
      compute = orphaned_task()
      {:ok, record} = Memory.get(compute.id)

      opts =
        record.opts
        |> Keyword.put(:max_runtime_ms, sixty_days)
        |> Keyword.put(:heartbeat_ms, sixty_days)
        |> Keyword.put(:status_poll_ms, sixty_days)

      :ok = Memory.put(%{record | opts: opts, max_runtime_ms: sixty_days})

      log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
      refute log =~ "could not start a tracker"

      assert {:ok, %{max_runtime_remaining_ms: remaining}} = Orchestrator.info(compute.id)
      assert remaining <= 4_294_967_295
      assert remaining > 4_294_967_295 - 60_000
    end
  end

  @hour 60 * 60 * 1_000

  # Give an orphaned task's record a cost cap and a meter, as a capped
  # persisted task writes them. `since_ago_ms` is how long before now the open
  # segment began; negative puts it in the future.
  defp cap_record!(id, max_cost, spent_usd, cost_rate, since_ago_ms) do
    {:ok, record} = Memory.get(id)

    :ok =
      Memory.put(%{
        record
        | max_cost: max_cost,
          spent_usd: spent_usd,
          cost_rate: cost_rate,
          cost_since_ms: System.system_time(:millisecond) - since_ago_ms
      })
  end

  describe "the carried cost cap" do
    test "a budget spent while the node was down fails the task at once" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0})
      # $1 an hour for three hours against a $2.50 cap. A fresh meter would
      # give the pod another two and a half hours.
      cap_record!(compute.id, 2.5, 0.0, 1.0, 3 * @hour)

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Adopter.run(notify: self())

      id = compute.id
      assert_receive {:atlas_compute, ^id, {:task, {:failed, :cost_cap}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a budget with money left resumes with the stored spend plus the downtime" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0})
      cap_record!(compute.id, 2.5, 0.5, 1.0, @hour)

      :ok = Adopter.run(notify: self())

      # $0.50 stored, plus an hour at $1 while the node was down.
      assert {:ok, %{max_cost: 2.5, spent_usd: spent, compute: %{status: :running}}} =
               Orchestrator.info(compute.id)

      assert_in_delta spent, 1.5, 0.01
    end

    test "the downtime counts at the last known rate, not the adopted pod's" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 2.0})
      cap_record!(compute.id, 10, 0.0, 1.0, @hour)

      :ok = Adopter.run(notify: self())

      assert {:ok, %{spent_usd: spent}} = Orchestrator.info(compute.id)
      assert_in_delta spent, 1.0, 0.01
    end

    test "an adopted pod at a new price records the spend so far and its price" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 2.0})
      cap_record!(compute.id, 10, 0.0, 1.0, @hour)

      :ok = Adopter.run(notify: self())
      {:ok, _info} = Orchestrator.info(compute.id)

      # A second restart now must count the hour at $1 once, then $2 an hour.
      assert {:ok, %{spent_usd: spent, cost_rate: 2.0, cost_since_ms: since}} =
               Memory.get(compute.id)

      assert_in_delta spent, 1.0, 0.01
      assert_in_delta since, System.system_time(:millisecond), 5_000
    end

    test "a price change after adoption rewrites the record's spend and price" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0}, status_poll_ms: 10)
      cap_record!(compute.id, 10, 0.0, 1.0, @hour)
      :ok = Adopter.run(notify: self())
      {:ok, _info} = Orchestrator.info(compute.id)

      :ok = Mock.set_cost_per_hour(compute.id, 3.0)

      assert %{spent_usd: spent} = Memory.await(compute.id, &(&1.cost_rate == 3.0))
      assert_in_delta spent, 1.0, 0.01
    end

    test "a record from a store without the cost columns still adopts on its deadline" do
      for {name, strip} <- [
            {"atlas-dropped", &Map.drop(&1, [:max_cost, :spent_usd, :cost_rate, :cost_since_ms])},
            {"atlas-nils",
             &%{&1 | max_cost: nil, spent_usd: nil, cost_rate: nil, cost_since_ms: nil}}
          ] do
        compute = orphaned_task(name: name)
        {:ok, record} = Memory.get(compute.id)
        :ok = Memory.put(strip.(record))
        backdate!(compute.id, 30 * 60 * 1_000)

        :ok = Adopter.run(notify: self())

        # Uncapped, but tracked: the deadline still ends it.
        assert {:ok, %{max_cost: false, max_runtime_remaining_ms: remaining}} =
                 Orchestrator.info(compute.id)

        assert remaining < 65 * 60 * 1_000
      end
    end

    test "a cap with no stored meter adopts capped, on a fresh budget" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0})
      {:ok, record} = Memory.get(compute.id)

      :ok =
        Memory.put(%{record | max_cost: 2.5, spent_usd: nil, cost_rate: nil, cost_since_ms: nil})

      :ok = Adopter.run(notify: self())

      assert {:ok, %{max_cost: 2.5, spent_usd: spent, compute: %{status: :running}}} =
               Orchestrator.info(compute.id)

      assert_in_delta spent, 0.0, 0.01
    end

    test "a wall clock that moved backwards refunds nothing" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0})
      cap_record!(compute.id, 10, 0.5, 1.0, -@hour)

      :ok = Adopter.run(notify: self())

      assert {:ok, %{spent_usd: spent}} = Orchestrator.info(compute.id)
      assert_in_delta spent, 0.5, 0.01
    end

    test "an adopted task raises its spend to the bill, asked from the first spawn" do
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0}, reconcile_spend_ms: 20)
      # $0.50 stored plus an hour of downtime at $1: $1.50 by the estimate.
      cap_record!(compute.id, 10, 0.5, 1.0, @hour)
      # Spawned 30 minutes earlier by the record than by the Mock's timestamp,
      # and inside the task's 90-minute deadline.
      %{spawned_at_ms: spawned_at_ms} = backdate!(compute.id, div(@hour, 2))
      spawned_at_ms = spawned_at_ms - div(@hour, 2)
      :ok = Mock.set_spend(compute.id, 4.0)

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconciled, %{billed_usd: 4.0, spent_usd: spent}}},
                     2_000

      assert_in_delta spent, 4.0, 0.01
      # The record keeps the open hour at $1 outside `spent_usd`: $0.50 stored
      # plus the $2.50 the bill added.
      assert %{spent_usd: recorded} = Memory.await(id, &(&1.spent_usd > 0.5))
      assert_in_delta recorded, 3.0, 0.01

      assert [%{from: from} | _] = Mock.spend_requests(id)
      assert DateTime.to_unix(from, :millisecond) == spawned_at_ms
    end

    test "a capped record from a store without the cost columns adopts and never bills" do
      compute =
        orphaned_task(
          provider_opts: %{cost_per_hour: 1.0},
          max_cost: 10,
          reconcile_spend_ms: 20
        )

      {:ok, record} = Memory.get(compute.id)

      :ok =
        Memory.put(%{record | max_cost: nil, spent_usd: nil, cost_rate: nil, cost_since_ms: nil})

      :ok = Adopter.run(notify: self())
      [{pid, _}] = Registry.lookup(ExAtlas.Orchestrator.ComputeRegistry, {:compute, compute.id})
      ref = Process.monitor(pid)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert Mock.spend_requests(compute.id) == []
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "an adopted bill below the session's stored spend changes nothing" do
      # The record does not say which pod spent its $3, so the bill for this
      # pod is compared with all of it: a lower bill never adds spend twice.
      compute = orphaned_task(provider_opts: %{cost_per_hour: 1.0}, reconcile_spend_ms: 20)
      cap_record!(compute.id, 10, 3.0, 1.0, 0)
      :ok = Mock.set_spend(compute.id, 2.0)

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconciled, %{billed_usd: 2.0, spent_usd: spent}}},
                     2_000

      assert_in_delta spent, 3.0, 0.01
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

  describe "a task with s3: staging" do
    @s3 %{
      access_key_id: "tid-test-4b1e",
      secret_access_key: "tsec-test-9f2c",
      dataset_uri: "s3://bucket/datasets/abc/"
    }

    defp orphaned_staged_task(image) do
      orphaned_task(
        image: image,
        s3: @s3,
        spot: true,
        on_failure: {:respawn, 1},
        status_poll_ms: 30
      )
    end

    defp images do
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      Enum.map(computes, & &1.image)
    end

    test "adopts, and a respawn after adoption ends the task without renting" do
      compute = orphaned_staged_task("trainer-adopted-s3:latest")
      id = compute.id

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      {:ok, pid} = Orchestrator.lookup(id)
      assert {:ok, %{mode: :task}} = Orchestrator.info(id)
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed,
                       {:preempted, %ExAtlas.Error{kind: :validation, message: message}}}},
                     2_000

      assert message =~ "credentials are not stored"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-adopted-s3:latest" in images()
      assert :error = Memory.get(id)
    end

    test "a host store that dropped the marker still adopts, and still refuses the respawn" do
      compute = orphaned_staged_task("trainer-adopted-s3-nomarker:latest")
      id = compute.id

      # A host store that keeps only the fields it has columns for hands back
      # the URIs without `credentials: :not_stored`. `Staging.new/1` would
      # accept that `s3:`, and a replacement would rent with no keys.
      {:ok, record} = Memory.get(id)

      :ok =
        Memory.put(%{
          record
          | opts: Keyword.put(record.opts, :s3, Map.delete(record.opts[:s3], :credentials))
        })

      {:ok, %{opts: stored}} = Memory.get(id)
      assert stored[:s3] == %{dataset_uri: "s3://bucket/datasets/abc/"}

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      assert {:ok, %{mode: :task}} = Orchestrator.info(id)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-adopted-s3-nomarker:latest" in images()
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

      log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
      assert_receive :adoption_complete, 2_000
      assert log =~ "not adopting #{compute.id}: unknown schema version 4"

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

  # What a node of this release before the cost cap wrote: `v: 2`, an owner,
  # and no cost fields.
  defp downgrade_to_v2!(id) do
    {:ok, record} = Memory.get(id)

    :ok =
      Memory.put(
        record
        |> Map.drop([:max_cost, :spent_usd, :cost_rate, :cost_since_ms])
        |> Map.put(:v, 2)
      )

    {:ok, v2} = Memory.get(id)
    v2
  end

  describe "records written before the cost cap (v2)" do
    test "adopt with no cost cap and resume what is left of max_runtime_ms" do
      compute = orphaned_task_of("a")
      v2 = downgrade_to_v2!(compute.id)
      backdate!(compute.id, 30 * 60 * 1_000)

      boot_as("a")

      assert {:ok, %{max_cost: false, max_runtime_remaining_ms: remaining}} =
               Orchestrator.info(compute.id)

      assert remaining > 55 * 60 * 1_000
      assert remaining < 65 * 60 * 1_000

      # Read as it is; nothing migrates it on disk.
      assert {:ok, %{v: 2} = stored} = Memory.get(compute.id)
      assert stored == %{v2 | spawned_at_ms: stored.spawned_at_ms}
    end

    test "a claimed v2 record is written back as a full v3 record" do
      compute = orphaned_task_of(nil)
      downgrade_to_v2!(compute.id)

      boot_as("b")

      assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)

      assert {:ok,
              %{
                v: 3,
                owner: "b",
                max_cost: false,
                spent_usd: +0.0,
                cost_rate: nil,
                cost_since_ms: nil
              }} = Memory.get(compute.id)
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

      assert {:ok, %{v: 3, owner: "b", max_cost: false, spent_usd: +0.0}} =
               Memory.get(compute.id)
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
