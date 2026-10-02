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

  defp pod_token(%{raw: %{request: request}}),
    do: ExAtlas.Spec.ComputeRequest.container_env(request)["ATLAS_CALLBACK_TOKEN"]

  defp post_finish(token, exit_code), do: post(token, "/finish", ~s({"exit_code":#{exit_code}}))

  defp post(token, path, body) do
    :post
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> ExAtlas.Callback.Plug.call([])
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

    test "after a respawn, refuses the replaced pod's report and accepts the replacement's" do
      {:ok, pid, pod_a} =
        Orchestrator.spawn(
          task_opts(
            callback: "https://app.example.com/atlas/cb",
            spot: true,
            status_poll_ms: 30,
            on_failure: {:respawn, 2}
          )
        )

      old_id = pod_a.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))
      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      {:ok, pod_b} = Mock.get_compute(new_id, %{})
      assert {:ok, %{respawns: 1}} = Memory.get(new_id)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      TestOrchestrator.sync_registry()

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      assert post_finish(pod_token(pod_a), 0).status == 410
      refute_receive {:atlas_compute, ^new_id, {:task_report, _}}, 200

      assert post_finish(pod_token(pod_b), 4).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 4}}}, 2_000
    end
  end

  # A record 0.8.0 wrote: its callback descriptor has no attempt, and the pod's
  # token, minted from it, signs none. `respawns` is what 0.8.0 had spent.
  describe "a task whose pod holds a token with no attempt (0.8.0)" do
    defp orphaned_0_8_0_task(respawns, overrides \\ []) do
      compute =
        orphaned_task(
          Keyword.merge(
            [
              callback: "https://app.example.com/atlas/cb",
              spot: true,
              status_poll_ms: false,
              on_failure: {:respawn, 2}
            ],
            overrides
          )
        )

      {:ok, record} = Memory.get(compute.id)
      callback = Map.delete(Keyword.fetch!(record.opts, :callback), :attempt)
      opts = Keyword.put(record.opts, :callback, callback)
      :ok = Memory.put(%{record | opts: opts, respawns: respawns})

      {compute, ExAtlas.Callback.Token.mint(callback.task_id, callback.kinds)}
    end

    test "the pod's report is accepted after adoption" do
      {compute, claimless} = orphaned_0_8_0_task(0)
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      assert post_finish(claimless, 4).status == 202
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    # 0.8.0 respawned this task once: its current pod is claim-less too, and
    # reading a claim-less token as attempt 0 would refuse its real report.
    test "the pod 0.8.0 itself respawned still reports after adoption" do
      {compute, claimless} = orphaned_0_8_0_task(1)
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      assert post_finish(claimless, 4).status == 202
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    test "after this version respawns it, the replaced pod's report gets 410" do
      {compute, claimless} = orphaned_0_8_0_task(0, status_poll_ms: 30)
      old_id = compute.id
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      {:ok, pod_b} = Mock.get_compute(new_id, %{})
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      assert post_finish(claimless, 0).status == 410
      refute_receive {:atlas_compute, ^new_id, {:task_report, _}}, 200
      assert {:ok, %{status: :running}} = Mock.get_compute(new_id, %{})

      assert post_finish(pod_token(pod_b), 4).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    test "a restart after the respawn still refuses the replaced pod and accepts the replacement" do
      {compute, claimless} = orphaned_0_8_0_task(0, status_poll_ms: 30)
      old_id = compute.id
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      {:ok, pod_b} = Mock.get_compute(new_id, %{})
      assert {:ok, %{respawns: 1}} = Memory.get(new_id)

      {:ok, pid} = Orchestrator.lookup(new_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      TestOrchestrator.sync_registry()

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      assert post_finish(claimless, 0).status == 410
      refute_receive {:atlas_compute, ^new_id, {:task_report, _}}, 200

      assert post_finish(pod_token(pod_b), 4).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    # A host store that nils a field it does not know returns `attempt: nil`,
    # and `Callback.env/2` mints no attempt for it.
    test "a record whose attempt is nil reads as a pod with no attempt" do
      {compute, claimless} = orphaned_0_8_0_task(0)
      {:ok, record} = Memory.get(compute.id)
      callback = Map.put(Keyword.fetch!(record.opts, :callback), :attempt, nil)
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :callback, callback)})

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      assert post_finish(claimless, 4).status == 202
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    # The report passes the Registry check while the pod is the current one,
    # then waits in the tracker's mailbox behind the poll that respawns.
    test "a report queued behind the respawn is dropped" do
      {compute, claimless} =
        orphaned_0_8_0_task(0, provider: ExAtlas.Test.FaultyProvider, status_poll_ms: 30)

      old_id = compute.id
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      {:ok, pid} = Orchestrator.lookup(old_id)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      ExAtlas.Test.FaultyProvider.arm(:get_compute, {:block, self()})
      assert_receive {:blocked, :get_compute, poller}, 2_000
      ExAtlas.Test.FaultyProvider.reset()
      :ok = Mock.forget(old_id)

      :sys.suspend(pid)
      send(poller, :release)
      await_mailbox(pid)

      assert post_finish(claimless, 0).status == 202
      :sys.resume(pid)

      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      # A recorded report settles a vanished pod as finished, so it is never
      # respawned. The dropped report leaves the replacement preemptible.
      :ok = Mock.forget(new_id)
      assert_receive {:atlas_compute, ^new_id, {:respawned, _third_id}}, 2_000
      refute_received {:atlas_compute, _, {:task, :completed}}
    end

    defp await_mailbox(pid, tries \\ 2_000) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} when n > 0 ->
          :ok

        _ when tries > 0 ->
          Process.sleep(1)
          await_mailbox(pid, tries - 1)
      end
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

    # The refusal comes before any rent, so it spends no attempt. The record
    # outlives the task only when the DELETE of the old pod fails, and then the
    # next boot must not count an attempt that rented nothing.
    test "a respawn refused before the rent records no attempt" do
      compute =
        orphaned_task(
          provider: ExAtlas.Test.FaultyProvider,
          image: "trainer-adopted-s3-refused:latest",
          s3: @s3,
          spot: true,
          on_failure: {:respawn, 2},
          status_poll_ms: 30
        )

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      {:ok, pid} = Orchestrator.lookup(id)
      ref = Process.monitor(pid)

      ExAtlas.Test.FaultyProvider.arm(
        :terminate,
        {:error, ExAtlas.Error.new(:transport, provider: :mock)}
      )

      :ok = Mock.set_status(id, :stopped)

      assert_receive {:atlas_compute, ^id, {:respawn_failed, {:preempted, %ExAtlas.Error{}}}},
                     2_000

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert_received {:atlas_compute, ^id, {:terminate_failed, _}}
      assert {:ok, %{respawns: 0} = record} = Memory.get(id)
      assert Map.get(record, :respawning) == nil
    end

    test "scrub_keys: [:s3] keeps the marker, so the respawn is still refused" do
      # A host that scrubs `:s3` whole must not lose the refusal with it: a
      # record with no `s3:` would respawn a pod with no staging at all.
      TestOrchestrator.put_env(scrub_keys: [:s3])
      compute = orphaned_staged_task("trainer-adopted-s3-scrubbed:latest")
      id = compute.id

      assert {:ok, %{opts: opts}} = Memory.get(id)
      assert opts[:s3] == %{credentials: :not_stored}

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-adopted-s3-scrubbed:latest" in images()
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

  describe "a task with env:" do
    @env %{"HF_TOKEN" => "hf-adopt-probe-5b70", "WANDB_PROJECT" => "atlas"}

    defp orphaned_env_task(image, env \\ @env) do
      orphaned_task(
        image: image,
        env: env,
        spot: true,
        on_failure: {:respawn, 1},
        status_poll_ms: 30
      )
    end

    defp env_images do
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      Enum.map(computes, & &1.image)
    end

    # Adopt `id` and preempt it; returns the tracker's pid.
    defp adopt_and_preempt(id) do
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      {:ok, pid} = Orchestrator.lookup(id)
      assert {:ok, %{mode: :task}} = Orchestrator.info(id)
      :ok = Mock.forget(id)
      pid
    end

    test "a record holding env names alone refuses the respawn, naming them" do
      compute = orphaned_env_task("trainer-adopted-env-marked:latest")
      id = compute.id

      {:ok, record} = Memory.get(id)
      marked = %{"HF_TOKEN" => :not_stored, "WANDB_PROJECT" => :not_stored}
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, marked)})

      pid = adopt_and_preempt(id)
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed,
                       {:preempted, %ExAtlas.Error{kind: :validation, message: message}}}},
                     2_000

      assert message =~ "HF_TOKEN, WANDB_PROJECT"
      assert message =~ "not stored"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-adopted-env-marked:latest" in env_images()
    end

    test "adopts, and a respawn after adoption ends the task without renting" do
      compute = orphaned_env_task("trainer-adopted-env:latest")
      id = compute.id

      assert {:ok, %{opts: opts}} = Memory.get(id)
      assert opts[:env] == %{"HF_TOKEN" => :not_stored, "WANDB_PROJECT" => :not_stored}

      pid = adopt_and_preempt(id)
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed,
                       {:preempted, %ExAtlas.Error{kind: :validation, message: message}}}},
                     2_000

      assert message =~ ":env values (HF_TOKEN, WANDB_PROJECT) are not stored"
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute "trainer-adopted-env:latest" in env_images()
      assert :error = Memory.get(id)
    end

    test "scrub_keys: [:env] keeps the marker, so the respawn is still refused" do
      TestOrchestrator.put_env(scrub_keys: [:env])
      compute = orphaned_env_task("trainer-adopted-env-scrubbed:latest")
      id = compute.id

      assert {:ok, %{opts: opts}} = Memory.get(id)
      assert opts[:env] == :not_stored

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-adopted-env-scrubbed:latest" in env_images()
    end

    test "a record whose env: is the bare marker refuses the respawn" do
      compute = orphaned_env_task("trainer-adopted-env-bare:latest")
      id = compute.id

      {:ok, record} = Memory.get(id)
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, :not_stored)})

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute "trainer-adopted-env-bare:latest" in env_images()
    end

    test "a record written before env: names-only keeps its values sealed and respawns" do
      compute = orphaned_env_task("trainer-adopted-env-v3:latest")
      id = compute.id

      # What a node on 0a22ec4 wrote: the values themselves.
      {:ok, record} = Memory.get(id)
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, @env)})

      pid = adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert {:ok, %{compute: replacement}} = Orchestrator.info(new_id)
      assert ExAtlas.Spec.ComputeRequest.container_env(replacement.raw.request) == @env

      ref = Process.monitor(pid)

      log =
        capture_log(fn ->
          catch_exit(GenServer.call(pid, {:not_a_call, 1}))
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        end)

      # The stacktrace printed the adopted opts, so the refute is not vacuous.
      assert log =~ "handle_call"
      assert log =~ "HF_TOKEN"
      refute log =~ "hf-adopt-probe-5b70"
    end

    # What a node on 0a22ec4 wrote: the values themselves.
    defp put_plain_env!(id) do
      {:ok, record} = Memory.get(id)
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, @env)})
    end

    defp assert_names_only(id) do
      assert {:ok, %{opts: opts}} = Memory.get(id)
      assert opts[:env] == %{"HF_TOKEN" => :not_stored, "WANDB_PROJECT" => :not_stored}
    end

    test "a respawn from an old record stores the replacement's env as names only" do
      compute = orphaned_env_task("trainer-adopted-env-v3-carry:latest")
      id = compute.id
      put_plain_env!(id)

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert_names_only(new_id)
    end

    test "a record update after adopting an old record stores env names only" do
      compute = orphaned_env_task("trainer-adopted-env-v3-update:latest")
      id = compute.id
      put_plain_env!(id)
      cap_record!(id, 10, 0.0, 1.0, @hour)
      :ok = Mock.set_cost_per_hour(id, 2.0)

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      # The adopted pod's new price rewrote the record.
      assert {:ok, %{cost_rate: 2.0}} = Memory.get(id)
      assert_names_only(id)
    end

    test "claiming an unowned old record stores env names only, and still respawns" do
      compute =
        orphaned_task_of(nil,
          image: "trainer-adopted-env-claim:latest",
          env: @env,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 30
        )

      id = compute.id
      {:ok, record} = Memory.get(id)
      :ok = Memory.put(%{record | owner: nil, opts: Keyword.put(record.opts, :env, @env)})

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      boot_as("b")

      assert {:ok, %{owner: "b"}} = Memory.get(id)
      assert_names_only(id)

      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert {:ok, %{compute: replacement}} = Orchestrator.info(new_id)
      assert ExAtlas.Spec.ComputeRequest.container_env(replacement.raw.request) == @env
    end

    test "a host store that turned the marker into a string still refuses the respawn" do
      compute = orphaned_env_task("trainer-adopted-env-string:latest")
      id = compute.id

      {:ok, record} = Memory.get(id)
      json_like = %{"HF_TOKEN" => "not_stored", "WANDB_PROJECT" => "not_stored"}
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, json_like)})

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute "trainer-adopted-env-string:latest" in env_images()
    end

    test "a host store that turned the bare marker into a string still refuses the respawn" do
      compute = orphaned_env_task("trainer-adopted-env-bare-string:latest")
      id = compute.id

      {:ok, record} = Memory.get(id)
      :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :env, "not_stored")})

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation}}}},
                     2_000

      refute "trainer-adopted-env-bare-string:latest" in env_images()
    end

    test "control: an empty env: respawns after adoption" do
      compute = orphaned_env_task("trainer-adopted-env-empty:latest", %{})
      id = compute.id

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, _new_id}}, 2_000
      assert "trainer-adopted-env-empty:latest" in env_images()
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

  describe "a task with respawn_credentials:" do
    alias ExAtlas.Spec.ComputeRequest
    alias ExAtlas.Test.CredentialResolver

    # Each value is distinctive, so a refute on any printout or byte string
    # can only pass because the value is not there.
    @orig_s3 %{
      access_key_id: "tid-orig-1f3a",
      secret_access_key: "tsec-orig-6b2d",
      dataset_uri: "s3://bucket/datasets/resolver/",
      region: "auto"
    }
    @orig_env %{"HF_TOKEN" => "hf-orig-3c9e", "WANDB_PROJECT" => "wandb-orig-8f11"}
    @creds %{access_key_id: "tid-resolved-7a41", secret_access_key: "tsec-resolved-0e58"}
    @resolved_env %{"HF_TOKEN" => "hf-resolved-91d2", "WANDB_PROJECT" => "wandb-resolved-5c07"}
    @resolved_values ~w(tid-resolved-7a41 tsec-resolved-0e58 hf-resolved-91d2 wandb-resolved-5c07)
    @ok_both :fixed

    defp resolver(script), do: {CredentialResolver, :resolve, [script]}

    defp orphaned_resolved_task(image, script, overrides \\ []) do
      orphaned_task(
        Keyword.merge(
          [
            image: image,
            s3: @orig_s3,
            env: @orig_env,
            spot: true,
            on_failure: {:respawn, 1},
            status_poll_ms: 30,
            user_id: "user-42",
            respawn_credentials: resolver({:report, self(), script})
          ],
          overrides
        )
        # `respawn_credentials: nil` stands for a task spawned without one.
        |> Enum.reject(&(&1 == {:respawn_credentials, nil}))
      )
    end

    defp mock_images do
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      Enum.map(computes, & &1.image)
    end

    defp container_env_of(id) do
      {:ok, %{compute: compute}} = Orchestrator.info(id)
      ComputeRequest.container_env(compute.raw.request)
    end

    # The respawn ended the task: a validation error naming the resolver, the
    # tracker gone, nothing rented, the record removed. Returns the message.
    defp assert_refused(id, pid, image) do
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id,
                      {:respawn_failed,
                       {:preempted, %ExAtlas.Error{kind: :validation, message: message}}}},
                     2_000

      # The tracker may be gone before the monitor lands (`:noproc`), so the
      # `:terminating` event shows how it stopped: normally, not by a crash.
      assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc],
                     2_000

      assert_received {:atlas_compute, ^id, {:terminating, :normal}}
      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute image in mock_images()
      assert :error = Memory.get(id)
      message
    end

    test "an adopted s3: and env: task respawns with the resolved values" do
      compute = orphaned_resolved_task("trainer-resolved:latest", @ok_both)
      id = compute.id

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      env = container_env_of(new_id)

      assert env["AWS_ACCESS_KEY_ID"] == "tid-resolved-7a41"
      assert env["AWS_SECRET_ACCESS_KEY"] == "tsec-resolved-0e58"
      assert env["ATLAS_DATASET_URI"] == "s3://bucket/datasets/resolver/"
      assert env["AWS_REGION"] == "auto"
      assert env["HF_TOKEN"] == "hf-resolved-91d2"
      assert env["WANDB_PROJECT"] == "wandb-resolved-5c07"
    end

    test "the resolver gets what the record keeps, and no value" do
      compute = orphaned_resolved_task("trainer-resolved-info:latest", @ok_both)
      id = compute.id

      adopt_and_preempt(id)

      assert_receive {:resolver_called, info}, 2_000

      assert info == %{
               id: id,
               name: "atlas-adoptable",
               user_id: "user-42",
               provider: :mock,
               s3: %{dataset_uri: "s3://bucket/datasets/resolver/", region: "auto"},
               env_names: ["HF_TOKEN", "WANDB_PROJECT"]
             }
    end

    test "an adopted s3:-only task respawns with the resolved credentials" do
      compute =
        orphaned_resolved_task("trainer-resolved-s3:latest", :fixed_s3, env: %{})

      id = compute.id
      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      env = container_env_of(new_id)
      assert env["AWS_ACCESS_KEY_ID"] == "tid-resolved-7a41"
      assert env["AWS_SECRET_ACCESS_KEY"] == "tsec-resolved-0e58"
      refute Map.has_key?(env, "HF_TOKEN")
    end

    test "an adopted env:-only task respawns with a value for every stored name" do
      compute =
        orphaned_resolved_task(
          "trainer-resolved-env:latest",
          {:return, {:ok, env: Map.put(@resolved_env, "EXTRA", "extra-ok")}},
          s3: nil
        )

      id = compute.id
      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert container_env_of(new_id) == Map.put(@resolved_env, "EXTRA", "extra-ok")
    end

    test "the replacement's record keeps the markers and the tuple, never a resolved value" do
      compute = orphaned_resolved_task("trainer-resolved-record:latest", @ok_both)
      id = compute.id

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert {:ok, record} = Memory.get(new_id)

      assert record.opts[:s3] == %{
               dataset_uri: "s3://bucket/datasets/resolver/",
               region: "auto",
               credentials: :not_stored
             }

      assert record.opts[:env] == %{"HF_TOKEN" => :not_stored, "WANDB_PROJECT" => :not_stored}
      assert record.opts[:respawn_credentials] == resolver({:report, self(), @ok_both})

      printed = inspect(record, limit: :infinity, structs: false)
      for value <- @resolved_values, do: refute(printed =~ value, "#{value} reached the record")
    end

    test "the resolved values reach no event, log line or crash report" do
      compute = orphaned_resolved_task("trainer-resolved-print:latest", @ok_both)
      id = compute.id

      log =
        capture_log(fn ->
          pid = adopt_and_preempt(id)
          assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
          Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

          status = inspect(:sys.get_status(pid), limit: :infinity, structs: false)
          # Control: the state holds the env names, so the status printed opts.
          assert status =~ "HF_TOKEN"
          for value <- @resolved_values, do: refute(status =~ value)

          ref = Process.monitor(pid)
          catch_exit(GenServer.call(pid, {:not_a_call, 1}))
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        end)

      # Control: the crash report printed the tracker's opts.
      assert log =~ "handle_call"
      assert log =~ "WANDB_PROJECT"
      for value <- @resolved_values, do: refute(log =~ value, "#{value} reached the log")

      # Control: the crash's `{:terminating, reason}` event carries the state.
      events = inspect(drain_events(), limit: :infinity, structs: false)
      assert events =~ "WANDB_PROJECT"
      for value <- @resolved_values, do: refute(events =~ value, "#{value} reached an event")
    end

    test "a second respawn in the same VM reuses the resolved values" do
      compute =
        orphaned_resolved_task("trainer-resolved-twice:latest", @ok_both,
          on_failure: {:respawn, 2}
        )

      id = compute.id
      adopt_and_preempt(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert_receive {:resolver_called, _info}, 2_000

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      :ok = Mock.forget(new_id)
      assert_receive {:atlas_compute, ^new_id, {:respawned, third_id}}, 2_000

      assert container_env_of(third_id)["HF_TOKEN"] == "hf-resolved-91d2"
      refute_received {:resolver_called, _info}
    end

    test "an error return ends the task, naming the resolver and no value" do
      compute =
        orphaned_resolved_task(
          "trainer-resolver-error:latest",
          {:return, {:error, :vault_down_4e2a}}
        )

      id = compute.id
      pid = adopt_and_preempt(id)
      message = assert_refused(id, pid, "trainer-resolver-error:latest")

      assert message =~ "ExAtlas.Test.CredentialResolver.resolve/2"
      assert message =~ "returned an error"
      refute message =~ "vault_down_4e2a"
    end

    test "a raise, throw or exit ends the task, and nothing prints its value" do
      for {script, n} <-
            Enum.with_index([
              {:raise, "tsec-raise-leak-44ab"},
              {:throw, "tsec-throw-leak-19cd"},
              {:exit, "tsec-exit-leak-7be0"}
            ]) do
        image = "trainer-resolver-crash-#{n}:latest"

        log =
          capture_log(fn ->
            compute = orphaned_resolved_task(image, script, name: "atlas-crash-#{n}")
            id = compute.id
            pid = adopt_and_preempt(id)
            message = assert_refused(id, pid, image)
            send(self(), {:message, message})
          end)

        assert_received {:message, message}
        assert message =~ "ExAtlas.Test.CredentialResolver.resolve/2"
        assert message =~ ~r/raised RuntimeError|threw|exited/

        for printed <- [message, log],
            leak <- ~w(tsec-raise-leak-44ab tsec-throw-leak-19cd tsec-exit-leak-7be0),
            do: refute(printed =~ leak, "#{leak} was printed")
      end
    end

    test "a result missing a stored env name ends the task, naming the name" do
      compute =
        orphaned_resolved_task(
          "trainer-resolver-partial:latest",
          {:merge_s3, @creds, [env: %{"HF_TOKEN" => "hf-resolved-91d2"}]}
        )

      id = compute.id
      pid = adopt_and_preempt(id)
      message = assert_refused(id, pid, "trainer-resolver-partial:latest")

      assert message =~ "WANDB_PROJECT"
      refute message =~ "HF_TOKEN,"
      refute message =~ "hf-resolved-91d2"
    end

    test "a result the replacement could not use ends the task without a crash" do
      # Each case with the part of the message that names what was wrong.
      bad_results = [
        {{:return, {:ok, env: @resolved_env}}, "returned no :s3"},
        {:fixed_s3, "returned no :env"},
        {{:return, {:ok, s3: nil, env: @resolved_env}}, "returned s3: nil"},
        # The stored marker passed back, as a careless merge would.
        {{:return, {:ok, s3: Map.put(@creds, :credentials, :not_stored), env: @resolved_env}},
         "credentials: :not_stored"},
        # `spawn_compute/1` raises on an `env:` that sets a variable `s3:` sets.
        {{:merge_s3, @creds, [env: Map.put(@resolved_env, "AWS_REGION", "us-east-1")]},
         "AWS_REGION"},
        {{:merge_s3, @creds, [env: %{@resolved_env | "HF_TOKEN" => 42}]},
         ~s(the value of "HF_TOKEN" is not a string)},
        {{:merge_s3, @creds, [env: @resolved_env, api_key: "sk-not-mine"]}, "the key :api_key"},
        {{:merge_s3, @creds, [env: :not_a_map]}, ":env that is not a map"},
        {{:return, {:ok, %{s3: @creds}}}, "not a keyword list"},
        {{:return, :ok}, "something other than {:ok, keyword}"}
      ]

      for {{script, expected}, n} <- Enum.with_index(bad_results) do
        image = "trainer-resolver-bad-#{n}:latest"
        compute = orphaned_resolved_task(image, script, name: "atlas-bad-#{n}")
        id = compute.id
        pid = adopt_and_preempt(id)
        message = assert_refused(id, pid, image)

        assert message =~ "ExAtlas.Test.CredentialResolver.resolve/2", "case #{n}: #{message}"
        assert message =~ expected, "case #{n}: #{message}"

        for value <- ["sk-not-mine" | @resolved_values],
            do: refute(message =~ value, "case #{n} printed a value")
      end
    end

    test "a result whose check raises ends the task, and nothing prints the value" do
      image = "trainer-resolver-raising-check:latest"

      log =
        capture_log(fn ->
          compute =
            orphaned_resolved_task(image, :broken_secret, s3: nil)

          pid = adopt_and_preempt(compute.id)
          send(self(), {:message, assert_refused(compute.id, pid, image)})
        end)

      assert_received {:message, message}
      assert message =~ "ExAtlas.Test.CredentialResolver.resolve/2"
      assert message =~ "raised BadFunctionError"
      refute message =~ "hf-badfun-leak-3d6a"
      refute log =~ "hf-badfun-leak-3d6a"
    end

    test "a resolver that never answers ends the task at the configured bound" do
      TestOrchestrator.put_env(respawn_credentials_timeout_ms: 50)
      compute = orphaned_resolved_task("trainer-resolver-hang:latest", {:hang, self()})
      id = compute.id

      pid = adopt_and_preempt(id)
      assert_receive {:resolver_started, resolver_pid}, 2_000
      message = assert_refused(id, pid, "trainer-resolver-hang:latest")

      assert message =~ "did not answer within 50 ms"
      refute Process.alive?(resolver_pid)
    end

    test "an answer after the bound is dropped, not used" do
      TestOrchestrator.put_env(respawn_credentials_timeout_ms: 50)

      compute =
        orphaned_resolved_task(
          "trainer-resolver-late:latest",
          {:sleep, 300, {:ok, s3: Map.merge(@creds, %{dataset_uri: "s3://b/d/"})}},
          env: %{}
        )

      id = compute.id
      pid = adopt_and_preempt(id)
      assert_refused(id, pid, "trainer-resolver-late:latest")

      Process.sleep(400)
      refute_received {:atlas_compute, ^id, {:respawned, _}}
      refute "trainer-resolver-late:latest" in mock_images()
    end

    test "an answer inside the bound respawns" do
      TestOrchestrator.put_env(respawn_credentials_timeout_ms: 1_000)

      compute =
        orphaned_resolved_task(
          "trainer-resolver-slow:latest",
          {:sleep, 100, {:ok, s3: Map.merge(@creds, %{dataset_uri: "s3://b/d/"})}},
          env: %{}
        )

      id = compute.id
      adopt_and_preempt(id)
      assert_receive {:atlas_compute, ^id, {:respawned, _new_id}}, 2_000
    end

    test "the default bound and the largest bound let a prompt answer through" do
      for {bound, n} <- Enum.with_index([nil, ExAtlas.Orchestrator.Timer.max_ms()]) do
        TestOrchestrator.put_env(respawn_credentials_timeout_ms: bound)
        image = "trainer-resolver-bound-#{n}:latest"

        compute =
          orphaned_resolved_task(image, {:sleep, 100, {:ok, env: @resolved_env}},
            s3: nil,
            name: "atlas-bound-#{n}"
          )

        id = compute.id
        adopt_and_preempt(id)
        assert_receive {:atlas_compute, ^id, {:respawned, _new_id}}, 2_000
      end
    end

    test "an invalid bound ends the task, naming the setting" do
      for {bound, n} <-
            Enum.with_index([0, -1, "30s", 1.5, ExAtlas.Orchestrator.Timer.max_ms() + 1]) do
        TestOrchestrator.put_env(respawn_credentials_timeout_ms: bound)
        image = "trainer-resolver-badbound-#{n}:latest"

        compute =
          orphaned_resolved_task(image, {:return, {:ok, env: @resolved_env}},
            s3: nil,
            name: "atlas-badbound-#{n}"
          )

        id = compute.id
        pid = adopt_and_preempt(id)
        message = assert_refused(id, pid, image)
        assert message =~ "respawn_credentials_timeout_ms", "bound #{inspect(bound)}"
      end
    end

    test "a record with no tuple uses the app config's resolver" do
      TestOrchestrator.put_env(respawn_credentials: resolver({:report, self(), @ok_both}))

      compute =
        orphaned_resolved_task("trainer-resolver-config:latest", @ok_both,
          respawn_credentials: nil
        )

      id = compute.id
      {:ok, record} = Memory.get(id)
      refute Keyword.has_key?(record.opts, :respawn_credentials)

      adopt_and_preempt(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert container_env_of(new_id)["HF_TOKEN"] == "hf-resolved-91d2"
    end

    test "the record's tuple wins over the app config's" do
      TestOrchestrator.put_env(
        respawn_credentials: resolver({:return, {:error, :the_config_resolver_ran}})
      )

      compute = orphaned_resolved_task("trainer-resolver-precedence:latest", @ok_both)
      id = compute.id

      adopt_and_preempt(id)
      assert_receive {:atlas_compute, ^id, {:respawned, _new_id}}, 2_000
    end

    test "a malformed app config resolver ends the task, naming the setting" do
      TestOrchestrator.put_env(respawn_credentials: {CredentialResolver, "resolve", []})

      compute =
        orphaned_resolved_task("trainer-resolver-badconfig:latest", @ok_both,
          respawn_credentials: nil
        )

      id = compute.id
      pid = adopt_and_preempt(id)
      message = assert_refused(id, pid, "trainer-resolver-badconfig:latest")
      assert message =~ "config :ex_atlas, :orchestrator, respawn_credentials"
    end

    test "a stored or configured resolver whose module lacks the behaviour is never called" do
      # `:erlang.send/2` is exported, and would send `info` here if it ran.
      undeclared = {:erlang, :send, [self()]}
      TestOrchestrator.put_env(respawn_credentials: undeclared)

      compute =
        orphaned_resolved_task("trainer-resolver-undeclared:latest", @ok_both,
          respawn_credentials: nil
        )

      id = compute.id
      {:ok, record} = Memory.get(id)
      opts = Keyword.put(record.opts, :respawn_credentials, undeclared)
      :ok = Memory.put(%{record | opts: opts})

      log = capture_log(fn -> send(self(), {:tracker, adopt_and_preempt(id)}) end)
      assert_received {:tracker, pid}
      message = assert_refused(id, pid, "trainer-resolver-undeclared:latest")

      # The stored tuple was dropped at adoption, and the configured one refused.
      assert log =~ "ExAtlas.Orchestrator.RespawnCredentials"
      assert message =~ "config :ex_atlas, :orchestrator, respawn_credentials"
      assert message =~ "ExAtlas.Orchestrator.RespawnCredentials"
      refute_received %{env_names: _}
    end

    test "a configured resolver with a struct in its args respawns, without a crash" do
      TestOrchestrator.put_env(
        respawn_credentials: {CredentialResolver, :resolve, [:fixed, ~D[2026-01-01]]}
      )

      compute =
        orphaned_resolved_task("trainer-resolver-struct-arg:latest", @ok_both,
          respawn_credentials: nil
        )

      id = compute.id
      adopt_and_preempt(id)
      assert_receive {:atlas_compute, ^id, {:respawned, _new_id}}, 2_000
    end

    test "scrub_keys: [:env] gives no names, and the result must hold env:" do
      TestOrchestrator.put_env(scrub_keys: [:env])

      compute =
        orphaned_resolved_task(
          "trainer-resolver-bare:latest",
          {:return, {:ok, env: @resolved_env}},
          s3: nil
        )

      id = compute.id
      adopt_and_preempt(id)

      assert_receive {:resolver_called, %{env_names: :unknown}}, 2_000
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert container_env_of(new_id) == @resolved_env
    end

    test "a task that never restarted respawns with its own values, not the resolver's" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            image: "trainer-resolver-unadopted:latest",
            s3: @orig_s3,
            env: @orig_env,
            spot: true,
            on_failure: {:respawn, 1},
            status_poll_ms: 30,
            respawn_credentials: resolver({:report, self(), @ok_both})
          )
        )

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      env = container_env_of(new_id)
      assert env["AWS_ACCESS_KEY_ID"] == "tid-orig-1f3a"
      assert env["HF_TOKEN"] == "hf-orig-3c9e"
      refute_received {:resolver_called, _info}
    end
  end

  defp drain_events(acc \\ []) do
    receive do
      {:atlas_compute, _id, _event} = message -> drain_events([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "a record whose respawn_credentials: no longer validates" do
    test "still adopts, and logs the dropped resolver" do
      for {bad, n} <-
            Enum.with_index([
              {"Elixir.ExAtlas.Test.CredentialResolver", "resolve", []},
              {ExAtlas.Test.NoSuchResolver, :resolve, []},
              {:erlang, :send, [self()]}
            ]) do
        compute = orphaned_task(name: "atlas-bad-resolver-#{n}")
        {:ok, record} = Memory.get(compute.id)
        :ok = Memory.put(%{record | opts: Keyword.put(record.opts, :respawn_credentials, bad)})

        log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
        assert_receive :adoption_complete, 2_000

        assert {:ok, %{mode: :task}} = Orchestrator.info(compute.id)
        assert log =~ "#{compute.id}"
        assert log =~ "respawn_credentials"
      end
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

  # Risk 51. Pod A is preempted, the tracker rents pod B, and the node dies
  # before the record moves to B. B runs on with a token for attempt 1 and no
  # tracker; the record still names A.
  describe "a node that dies while a respawn rents the replacement" do
    alias ExAtlas.Test.FaultyProvider

    defp died_mid_respawn(max_attempts) do
      {:ok, pid, pod_a} =
        Orchestrator.spawn(
          task_opts(
            provider: FaultyProvider,
            callback: "https://app.example.com/atlas/cb",
            spot: true,
            status_poll_ms: 30,
            on_failure: {:respawn, max_attempts}
          )
        )

      FaultyProvider.arm(:spawn_compute, {:block_after, self()})
      :ok = Mock.set_status(pod_a.id, :stopped)
      assert_receive {:blocked, :spawn_compute, ^pid}, 2_000
      FaultyProvider.reset()

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      TestOrchestrator.sync_registry()

      {:ok, pods} = Mock.list_compute([], %{})
      assert [pod_b] = Enum.reject(pods, &(&1.id == pod_a.id))
      assert {:ok, %{id: id}} = Memory.get(pod_a.id)
      assert id == pod_a.id
      assert :error = Memory.get(pod_b.id)

      {pod_a, pod_b}
    end

    test "the orphan's report gets 410, before and after the adopted task respawns" do
      {pod_a, pod_b} = died_mid_respawn(2)
      old_id = pod_a.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      # Hold the adopted tracker's first poll, so the task is adopted and has
      # not respawned yet: the window in which only the Registry decides.
      FaultyProvider.arm(:get_compute, {:block, self()})
      me = self()
      adopter = Task.async(fn -> Adopter.run(notify: me) end)
      assert_receive {:blocked, :get_compute, observer}, 2_000
      send(observer, :release)
      assert_receive {:blocked, :get_compute, poller}, 2_000
      FaultyProvider.reset()
      assert :ok = Task.await(adopter)
      assert_receive :adoption_complete, 2_000

      assert post_finish(pod_token(pod_b), 0).status == 410
      assert post_finish(pod_token(pod_a), 0).status == 410

      send(poller, :release)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      {:ok, pod_c} = Mock.get_compute(new_id, %{})
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      assert post_finish(pod_token(pod_b), 0).status == 410
      refute_receive {:atlas_compute, ^new_id, {:task_report, _}}, 200
      assert {:ok, %{status: :running}} = Mock.get_compute(new_id, %{})

      assert post_finish(pod_token(pod_c), 4).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 4}}}, 2_000
    end

    # The orphan bills until the Reaper or an operator deletes it, and only
    # this node knows it may exist.
    test "the adoption warns, naming the orphan's pod name and attempt" do
      {pod_a, _pod_b} = died_mid_respawn(2)

      log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)

      assert log =~ "adopting #{pod_a.id}"
      assert log =~ "attempt 1"
      assert log =~ ~s(named "atlas-adoptable")
      assert log =~ ":reap_providers"
    end

    # The orphan and the adopted task's replacement share the task's name and
    # the prefix. Only the live tracker separates them, so the replacement's
    # record is removed first: the Registry alone must keep it.
    test "the Reaper deletes the orphan and never the replacement a live tracker holds" do
      TestOrchestrator.put_env(reap_grace_ms: 0)
      {pod_a, pod_b} = died_mid_respawn(2)
      old_id = pod_a.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      :ok = Adopter.run(notify: self())
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      :ok = Memory.delete(new_id)
      assert {:ok, %{status: :running, name: name}} = Mock.get_compute(new_id, %{})
      assert name == pod_b.name

      :ok = ExAtlas.Orchestrator.Reaper.reap_now("atlas-", [FaultyProvider])

      assert {:ok, %{status: :terminated}} = Mock.get_compute(pod_b.id, %{})
      assert {:ok, %{status: :running}} = Mock.get_compute(new_id, %{})
      assert {:ok, %{compute: %{id: ^new_id}}} = Orchestrator.info(new_id)
    end

    test "the interrupted attempt counts as spent, so a spent budget rents nothing more" do
      {pod_a, _pod_b} = died_mid_respawn(1)
      old_id = pod_a.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert_receive {:atlas_compute, ^old_id, {:task, _outcome}}, 2_000
      refute_received {:atlas_compute, ^old_id, {:respawned, _}}
      assert {:ok, pods} = Mock.list_compute([], %{})
      assert length(pods) == 2
    end

    # A record 0.8.0 wrote has no `:respawning`; a host store that nils a
    # field it does not know returns `nil`. A host column with a default
    # returns 0, and a rollback's `carry_record` copies a stale intent equal to
    # `respawns`: neither is an attempt beyond `respawns`. All adopt as before
    # this field: the current pod reports, and the budget is what `respawns`
    # says.
    for shape <- [:missing, nil, 0] do
      test "a record with :respawning #{inspect(shape)} adopts and respawns as before" do
        compute =
          orphaned_task(
            provider: ExAtlas.Test.FaultyProvider,
            callback: "https://app.example.com/atlas/cb",
            spot: true,
            status_poll_ms: 30,
            on_failure: {:respawn, 1}
          )

        {:ok, record} = Memory.get(compute.id)

        record =
          case unquote(shape) do
            :missing -> Map.delete(record, :respawning)
            value -> Map.put(record, :respawning, value)
          end

        :ok = Memory.put(record)
        old_id = compute.id
        Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(old_id))

        log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
        assert_receive :adoption_complete, 2_000
        refute log =~ "rented the replacement"

        assert post(pod_token(compute), "/progress", ~s({"step":1})).status == 202
        assert_receive {:atlas_compute, ^old_id, {:progress, %{"step" => 1}}}, 2_000

        :ok = Mock.set_status(old_id, :stopped)
        assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000
      end
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
