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

    # Risk 51: a node that dies while the provider rents the replacement leaves
    # the record on the preempted pod. The record says which attempt started,
    # so the next boot can refuse a replacement it never heard of.
    test "a respawn records its attempt before it rents, and the replacement's record drops it" do
      on_exit(&ExAtlas.Test.FaultyProvider.reset/0)

      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            provider: ExAtlas.Test.FaultyProvider,
            spot: true,
            status_poll_ms: 30,
            on_failure: {:respawn, 2}
          )
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id
      assert {:ok, %{respawning: nil}} = Memory.get(old_id)

      ExAtlas.Test.FaultyProvider.arm(:spawn_compute, {:block, self()})
      :ok = Mock.set_status(old_id, :stopped)
      assert_receive {:blocked, :spawn_compute, tracker}, 2_000

      assert {:ok, %{respawns: 0, respawning: 1}} = Memory.get(old_id)

      ExAtlas.Test.FaultyProvider.reset()
      send(tracker, :release)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      assert {:ok, %{respawns: 1, respawning: nil}} = Memory.get(new_id)
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

    test "persists, and the record holds the URIs and the marker" do
      assert {:ok, _pid, compute} =
               Orchestrator.run_task(task_opts(image: "trainer-s3-persisted:latest", s3: @s3))

      assert {:ok, %{opts: opts}} = Memory.get(compute.id)

      assert opts[:s3] == %{
               dataset_uri: "s3://bucket/datasets/abc/",
               credentials: :not_stored
             }

      assert "trainer-s3-persisted:latest" in mock_images()
    end

    test "with max_cost and no s3: persists as before (control)" do
      assert {:ok, _pid, compute} =
               Orchestrator.run_task(
                 task_opts(max_cost: 2.5, provider_opts: %{cost_per_hour: 1.5})
               )

      assert {:ok, %{max_cost: 2.5, cost_rate: 1.5, opts: opts}} = Memory.get(compute.id)
      refute Keyword.has_key?(opts, :s3)
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

  describe "respawn_credentials:" do
    setup do
      ExAtlas.Test.Orchestrator.start!(tracking_store: Memory)
    end

    @resolver {ExAtlas.Test.CredentialResolver, :resolve, [{:return, {:ok, []}}]}

    test "is stored in the record as the tuple itself" do
      assert {:ok, _pid, compute} =
               Orchestrator.run_task(task_opts(respawn_credentials: @resolver))

      assert {:ok, %{opts: opts}} = Memory.get(compute.id)
      assert opts[:respawn_credentials] == @resolver
    end

    test "without persist: true is refused before anything is rented" do
      assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials} = error} =
               Orchestrator.run_task(task_opts(persist: false, respawn_credentials: @resolver))

      assert Exception.message(error) =~ "persist: true"
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
      assert {:ok, []} = Memory.all()
    end

    test "a malformed tuple is refused before anything is rented" do
      resolver = ExAtlas.Test.CredentialResolver

      for bad <- [
            {resolver, "resolve", []},
            {resolver, :resolve},
            {resolver, :resolve, [:a | :b]},
            fn _info -> {:ok, []} end
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials}} =
                 Orchestrator.run_task(task_opts(respawn_credentials: bad)),
               "accepted #{inspect(bad)}"
      end

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a module that does not declare the RespawnCredentials behaviour is refused" do
      # `:erlang.send/2` is exported and would send `info` to this process.
      assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials} = error} =
               Orchestrator.run_task(task_opts(respawn_credentials: {:erlang, :send, [self()]}))

      assert Exception.message(error) =~ "ExAtlas.Orchestrator.RespawnCredentials"
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "args holding a function or a Secret are refused, since the record stores them" do
      for args <- [
            [fn -> "hf-closure-arg-5a1c" end],
            [%{token: ExAtlas.Secret.wrap("hf-secret-arg-08be")}],
            [{:nested, [ExAtlas.Secret.wrap("hf-secret-arg-08be")]}]
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials} = error} =
                 Orchestrator.run_task(
                   task_opts(
                     respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, args}
                   )
                 )

        assert Exception.message(error) =~ "args"
      end

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "args holding structs, ranges, sets and improper lists validate without a raise" do
      for args <- [[~D[2026-01-01]], [URI.parse("https://x.example")], [1..3], [MapSet.new([1])]] do
        assert {:ok, _pid, _compute} =
                 Orchestrator.run_task(
                   task_opts(
                     respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, args}
                   )
                 ),
               "refused #{inspect(args)}"
      end

      # A Secret inside a struct or an improper tail is still found.
      for args <- [
            [URI.parse("https://x") |> Map.put(:host, ExAtlas.Secret.wrap("h"))],
            [[1 | ExAtlas.Secret.wrap("t")]]
          ] do
        assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials}} =
                 Orchestrator.run_task(
                   task_opts(
                     respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, args}
                   )
                 )
      end
    end

    test "an Erlang module that spells it -behavior(...) is accepted" do
      forms = [
        {:attribute, 1, :module, :ea87_erlang_resolver},
        {:attribute, 1, :behavior, ExAtlas.Orchestrator.RespawnCredentials},
        {:attribute, 1, :export, [resolve: 2]},
        {:function, 1, :resolve, 2,
         [{:clause, 1, [{:var, 1, :_S}, {:var, 1, :_I}], [], [{:atom, 1, :ok}]}]},
        {:eof, 1}
      ]

      {:ok, module, binary, _warnings} = :compile.forms(forms, [:binary, :return])
      {:module, ^module} = :code.load_binary(module, ~c"ea87_erlang_resolver.erl", binary)

      assert {:ok, _pid, _compute} =
               Orchestrator.run_task(task_opts(respawn_credentials: {module, :resolve, [:x]}))
    end

    test "a function the module does not export is refused, naming it" do
      assert {:error, %NimbleOptions.ValidationError{key: :respawn_credentials} = error} =
               Orchestrator.run_task(
                 task_opts(respawn_credentials: {ExAtlas.Test.CredentialResolver, :resolve, []})
               )

      assert Exception.message(error) =~ "ExAtlas.Test.CredentialResolver.resolve/1"
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end
  end

  describe "secrets" do
    @describetag :tmp_dir

    test "a record built from spawn opts keeps only s3:'s non-secret fields" do
      compute = %ExAtlas.Spec.Compute{id: "mock-s3", provider: :mock, status: :running}

      # `Orchestrator.spawn/1` hands the record a validated `Staging`.
      {:ok, staging} =
        ExAtlas.Spec.Staging.new(%{
          endpoint: "https://t3.storage.dev",
          region: "auto",
          access_key_id: "tid-test-4b1e",
          secret_access_key: "tsec-test-9f2c",
          session_token: "tses-test-0d7a",
          dataset_uri: "s3://bucket/datasets/abc/",
          artifact_uri: "s3://bucket/artifacts/run-123/",
          dataset_url: "https://b.example/d.tar.gz?X-Amz-Signature=getsig-5d0c91",
          artifact_url: "https://b.example/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"
        })

      opts = task_opts(s3: staging, env: %{"WANDB_PROJECT" => "x"})

      record = TrackingStore.new(compute, opts, mode: :task)

      assert record.opts[:s3] == %{
               endpoint: "https://t3.storage.dev",
               region: "auto",
               dataset_uri: "s3://bucket/datasets/abc/",
               artifact_uri: "s3://bucket/artifacts/run-123/",
               credentials: :not_stored
             }

      text = inspect(record, limit: :infinity, printable_limit: :infinity, structs: false)

      for secret <- ~w(tid-test-4b1e tsec-test-9f2c tses-test-0d7a getsig-5d0c91 putsig-a7e3b2),
          do: refute(text =~ secret)

      # Control: the rest of the opts are kept; `env:` keeps its names.
      assert record.opts[:image] == "trainer:latest"
      assert record.opts[:env] == %{"WANDB_PROJECT" => :not_stored}
    end

    test "env: values never reach the store's bytes on disk, and the names do",
         %{tmp_dir: dir} do
      ExAtlas.Test.Orchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})

      assert {:ok, _pid, compute} =
               Orchestrator.run_task(
                 task_opts(
                   env: %{
                     "HF_TOKEN_NAME_c31e" => "hf-disk-probe-8d4b",
                     "WANDB_NAME_02f9" => "wandb-disk-probe-e6a1"
                   }
                 )
               )

      bytes = File.read!(Path.join(dir, "tracked.dets"))

      # The record landed with its env names, so the refutes are not vacuous.
      assert bytes =~ compute.id
      assert bytes =~ "HF_TOKEN_NAME_c31e"
      assert bytes =~ "WANDB_NAME_02f9"
      refute bytes =~ "hf-disk-probe-8d4b"
      refute bytes =~ "wandb-disk-probe-e6a1"
      # No closure either: an `ExAtlas.Secret` must never reach disk.
      refute bytes =~ "ExAtlas.Secret"

      assert {:ok, record} = TrackingStore.Dets.get(compute.id)

      assert record.opts[:env] == %{
               "HF_TOKEN_NAME_c31e" => :not_stored,
               "WANDB_NAME_02f9" => :not_stored
             }
    end

    test "an empty env: is stored as it is, and no env: stores none" do
      assert TrackingStore.scrub_opts(env: %{}) == [env: %{}]
      assert TrackingStore.scrub_opts(image: "x") == [image: "x"]
    end

    test "scrub_keys: [:env] stores the bare marker, never nothing" do
      # `start!/1` clears the orchestrator config when the test exits.
      ExAtlas.Test.Orchestrator.start!()
      ExAtlas.Test.Orchestrator.put_env(scrub_keys: [:env])

      scrubbed = TrackingStore.scrub_opts(env: %{"HF_TOKEN" => "hf-scrub-probe-1a7c"}, image: "x")

      assert scrubbed[:env] == :not_stored
      assert scrubbed[:image] == "x"

      # An empty env has nothing to lose, so a respawn may still run.
      assert TrackingStore.scrub_opts(env: %{}) == [env: %{}]
    end

    test "presigned URLs alone leave only the marker" do
      {:ok, staging} =
        ExAtlas.Spec.Staging.new(
          dataset_url: "https://b.example/d.tar.gz?X-Amz-Signature=getsig-5d0c91"
        )

      assert TrackingStore.scrub_opts(s3: staging) == [s3: %{credentials: :not_stored}]
    end

    test "an s3: no one validated keeps only the marker" do
      # A tracker started directly holds the raw map; its endpoint was never
      # checked for user info.
      raw = %{endpoint: "https://u:tsec-test-9f2c@t3.storage.dev", dataset_uri: "s3://b/d/"}

      assert TrackingStore.scrub_opts(s3: raw) == [s3: %{credentials: :not_stored}]
      assert TrackingStore.scrub_opts(s3: Map.to_list(raw)) == [s3: %{credentials: :not_stored}]
    end

    test "s3: nil stays nil" do
      assert TrackingStore.scrub_opts(s3: nil) == [s3: nil]
    end

    test "s3: keys and presigned URLs never reach the store's bytes on disk",
         %{tmp_dir: dir} do
      ExAtlas.Test.Orchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})

      assert {:ok, _pid, compute} =
               Orchestrator.run_task(
                 task_opts(
                   s3: %{
                     endpoint: "https://t3-probe-51c0.storage.dev",
                     region: "auto",
                     access_key_id: "tid-test-4b1e",
                     secret_access_key: "tsec-test-9f2c",
                     session_token: "tses-test-0d7a",
                     dataset_uri: "s3://bucket/datasets/abc-probe-2e8f/",
                     artifact_uri: "s3://bucket/artifacts/run-probe-77d1/",
                     dataset_url: "https://b.example/d.tar.gz?X-Amz-Signature=getsig-5d0c91",
                     artifact_url: "https://b.example/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"
                   },
                   # Control: an env name is stored, so a string in a record
                   # shows up in these bytes as written.
                   env: %{"PROBE_NAME_4f2a" => "env-value-6e1d"}
                 )
               )

      bytes = File.read!(Path.join(dir, "tracked.dets"))

      assert bytes =~ "PROBE_NAME_4f2a"
      refute bytes =~ "env-value-6e1d"
      assert bytes =~ compute.id
      assert bytes =~ "t3-probe-51c0.storage.dev"
      assert bytes =~ "abc-probe-2e8f"
      assert bytes =~ "run-probe-77d1"

      for secret <- ~w(tid-test-4b1e tsec-test-9f2c tses-test-0d7a getsig-5d0c91 putsig-a7e3b2),
          do: refute(bytes =~ secret, "#{secret} reached the DETS file")
    end

    test "never reach the store's bytes on disk", %{tmp_dir: dir} do
      ExAtlas.Test.Orchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})

      {:ok, _pid, compute} =
        Orchestrator.spawn(
          task_opts(
            api_key: @api_key,
            auth: :bearer,
            req_options: [
              auth: {:bearer, @api_key},
              aws_sigv4: [access_key_id: "AKIDPROBE", secret_access_key: "sigv4-disk-probe-3c7e"]
            ]
          )
        )

      bytes = File.read!(Path.join(dir, "tracked.dets"))

      # The provider credential, however it was passed in.
      refute bytes =~ @api_key
      refute bytes =~ "sigv4-disk-probe-3c7e"

      # And the resource's own bearer token, which `ExAtlas.Auth.Token`'s
      # moduledoc promises ExAtlas never stores.
      assert is_binary(compute.auth.token)
      refute bytes =~ compute.auth.token

      # The record itself did land, so this is not passing by writing nothing.
      assert {:ok, %{id: id}} = TrackingStore.Dets.get(compute.id)
      assert id == compute.id
      assert bytes =~ compute.id
    end

    test "a task adopted from DETS respawns through its record's tuple, and no resolved value reaches the disk",
         %{tmp_dir: dir} do
      ExAtlas.Test.Orchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})

      # `:fixed` returns `CredentialResolver.credentials/0` and `env/0`, values
      # the record's args never hold.
      resolver = {ExAtlas.Test.CredentialResolver, :resolve, [:fixed]}

      {:ok, pid, compute} =
        Orchestrator.run_task(
          task_opts(
            image: "trainer-dets-resolver:latest",
            s3: %{
              access_key_id: "tid-dets-orig-91aa",
              secret_access_key: "tsec-dets-orig-5e37",
              dataset_uri: "s3://bucket/datasets/dets-probe-6a0d/"
            },
            env: %{"HF_TOKEN" => "hf-dets-orig-d81b", "WANDB_PROJECT" => "wandb-dets-orig-a3c2"},
            spot: true,
            on_failure: {:respawn, 1},
            status_poll_ms: 30,
            respawn_credentials: resolver
          )
        )

      # A deploy: the tracker dies without `terminate/2`, the store reopens
      # its file, and the next boot adopts from what DETS kept.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
      ExAtlas.Test.Orchestrator.sync_registry()
      stop_supervised!(TrackingStore.Dets)
      start_supervised!({TrackingStore.Dets, [storage_path: dir]})

      id = compute.id
      assert {:ok, %{opts: opts}} = TrackingStore.Dets.get(id)
      assert opts[:respawn_credentials] == resolver

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      :ok = ExAtlas.Orchestrator.Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      {:ok, %{compute: replacement}} = Orchestrator.info(new_id)
      env = ExAtlas.Spec.ComputeRequest.container_env(replacement.raw.request)
      assert env["AWS_SECRET_ACCESS_KEY"] == "tsec-resolved-0e58"
      assert env["ATLAS_DATASET_URI"] == "s3://bucket/datasets/dets-probe-6a0d/"
      assert env["WANDB_PROJECT"] == "wandb-resolved-5c07"

      bytes = File.read!(Path.join(dir, "tracked.dets"))

      # The replacement's record landed, with its names and URIs.
      assert bytes =~ new_id
      assert bytes =~ "WANDB_PROJECT"
      assert bytes =~ "dets-probe-6a0d"

      for secret <-
            ~w(tid-resolved-7a41 tsec-resolved-0e58 hf-resolved-91d2 wandb-resolved-5c07) ++
              ~w(tid-dets-orig-91aa tsec-dets-orig-5e37 hf-dets-orig-d81b wandb-dets-orig-a3c2),
          do: refute(bytes =~ secret, "#{secret} reached the DETS file")

      refute bytes =~ "ExAtlas.Secret"
    end
  end
end
