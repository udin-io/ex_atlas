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
               v: 3,
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

    test "an uncapped task records no cost cap and no meter" do
      {:ok, _pid, compute} = Orchestrator.spawn(task_opts())

      assert {:ok, %{max_cost: false, spent_usd: +0.0, cost_rate: nil, cost_since_ms: nil}} =
               Memory.get(compute.id)
    end

    test "a capped task records its cap and opens its meter at the pod's price" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(task_opts(max_cost: 2.5, provider_opts: %{cost_per_hour: 1.5}))

      assert {:ok, %{max_cost: 2.5, spent_usd: +0.0, cost_rate: 1.5, cost_since_ms: since}} =
               Memory.get(compute.id)

      # Wall clock, like `spawned_at_ms`, so a new VM can count the downtime.
      assert_in_delta since, System.system_time(:millisecond), 5_000
    end

    test "a price change on a capped task rewrites the record's spend and price" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            max_cost: 100,
            status_poll_ms: 10,
            provider_opts: %{cost_per_hour: 3600.0}
          )
        )

      :ok = Mock.set_cost_per_hour(compute.id, 7200.0)

      # The spend at $1 a second up to the change is closed into `spent_usd`.
      assert %{spent_usd: spent} = Memory.await(compute.id, &(&1.cost_rate == 7200.0))
      assert spent > 0.0
    end

    test "stamps the spawning node's owner into the record" do
      ExAtlas.Test.Orchestrator.put_env(reap_owner: "a")

      {:ok, _pid, compute} = Orchestrator.spawn(task_opts())

      assert {:ok, %{v: 3, owner: "a"}} = Memory.get(compute.id)
    end

    test "records no owner when the node has none" do
      {:ok, _pid, compute} = Orchestrator.spawn(task_opts())

      assert {:ok, %{v: 3, owner: nil}} = Memory.get(compute.id)
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
      ExAtlas.Test.Orchestrator.put_env(reap_owner: "a")

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
      assert replacement.owner == "a"

      # ...on the original deadline. A record that re-anchored here would hand
      # a preempted 90-minute task another 90 minutes on every replacement.
      assert replacement.spawned_at_ms == original.spawned_at_ms

      # ...and the pod that is gone must not be adopted at all.
      assert :error = Memory.get(old_id)
    end

    test "a respawn at the same price carries the open segment unchanged" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            spot: true,
            status_poll_ms: 10,
            on_failure: {:respawn, 1},
            max_cost: 100,
            provider_opts: %{cost_per_hour: 3600.0}
          )
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id
      {:ok, original} = Memory.get(old_id)

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      # Nothing reprices a replacement at the old price, so only the carried
      # record keeps the segment's start: a restart then counts it once.
      assert {:ok, replacement} = Memory.get(new_id)

      assert Map.take(replacement, [:max_cost, :spent_usd, :cost_rate, :cost_since_ms]) ==
               Map.take(original, [:max_cost, :spent_usd, :cost_rate, :cost_since_ms])
    end

    test "a respawn carries the spend into the replacement's record" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            spot: true,
            status_poll_ms: 10,
            on_failure: {:respawn, 1},
            max_cost: 100,
            provider_opts: %{cost_per_hour: 3600.0}
          )
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      # Close a segment, so the record holds spend worth carrying.
      :ok = Mock.set_cost_per_hour(old_id, 7200.0)
      %{spent_usd: spent_before} = Memory.await(old_id, &(&1.cost_rate == 7200.0))
      assert spent_before > 0.0

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      # The replacement runs at the spawn price again, so its record opens a
      # segment at 3600 on top of everything spent so far.
      assert {:ok, %{spent_usd: spent_after, cost_rate: 3600.0}} = Memory.get(new_id)
      assert spent_after > spent_before
    end

    test "a bill above the estimate rewrites the record's spend" do
      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            max_cost: 100,
            reconcile_spend_ms: 20,
            provider_opts: %{cost_per_hour: 0.36}
          )
        )

      {:ok, %{cost_since_ms: since}} = Memory.get(compute.id)
      :ok = Mock.set_spend(compute.id, 40.0)

      # The open segment keeps its start, so a restart counts from the same
      # moment on top of the billed spend.
      assert %{spent_usd: spent, cost_since_ms: raised_since, cost_rate: 0.36} =
               Memory.await(compute.id, &(&1.spent_usd >= 39.0))

      assert spent <= 40.0
      # The tracker restates the start from its monotonic clock, within a few ms.
      assert_in_delta raised_since, since, 1_000
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

    test "deletes a persisted task's pod when its tracking record is missing" do
      {:ok, pid, compute} = Orchestrator.spawn(task_opts())
      # No boot could adopt this pod, so keeping it would only bill.
      :ok = Memory.delete(compute.id)

      :ok = DynamicSupervisor.terminate_child(ComputeSupervisor, pid)

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
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
    test "an abnormal exit deletes a persisted task's pod and its record" do
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

  describe "persist: true with s3:" do
    setup do
      ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
    end

    @s3 %{
      access_key_id: "tid-test-4b1e",
      secret_access_key: "tsec-test-9f2c",
      dataset_uri: "s3://bucket/datasets/abc/"
    }

    defp mock_images do
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      Enum.map(computes, & &1.image)
    end

    test "is refused on :persist before the provider is called" do
      opts = task_opts(image: "trainer-s3-refused:latest", s3: @s3)

      assert {:error, %NimbleOptions.ValidationError{key: :persist, value: true} = error} =
               Orchestrator.run_task(opts)

      assert Exception.message(error) =~ ":s3"
      refute inspect(error) =~ "tsec-test-9f2c"
      refute "trainer-s3-refused:latest" in mock_images()
    end

    test "without s3: still persists (control)" do
      assert {:ok, _pid, compute} =
               Orchestrator.run_task(task_opts(image: "trainer-s3-control:latest"))

      assert {:ok, %{id: _}} = Memory.get(compute.id)
      assert "trainer-s3-control:latest" in mock_images()
    end

    test "with s3: nil still persists" do
      assert {:ok, _pid, compute} = Orchestrator.run_task(task_opts(s3: nil))
      assert {:ok, %{id: _}} = Memory.get(compute.id)
    end

    test "s3: without persist: true runs" do
      assert {:ok, _pid, compute} = Orchestrator.run_task(task_opts(persist: false, s3: @s3))
      assert :error = Memory.get(compute.id)
    end
  end

  describe "secrets" do
    @describetag :tmp_dir

    test "a record built from spawn opts drops s3:" do
      compute = %ExAtlas.Spec.Compute{id: "mock-s3", provider: :mock, status: :running}

      opts =
        task_opts(
          s3: %{
            access_key_id: "tid-test-4b1e",
            secret_access_key: "tsec-test-9f2c",
            artifact_uri: "s3://b/a"
          },
          env: %{"WANDB_PROJECT" => "x"}
        )

      record = TrackingStore.new(compute, opts, mode: :task)

      refute Keyword.has_key?(record.opts, :s3)
      refute inspect(record) =~ "tsec-test-9f2c"
      # Control: the rest of the opts are kept.
      assert record.opts[:env] == %{"WANDB_PROJECT" => "x"}
    end

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
