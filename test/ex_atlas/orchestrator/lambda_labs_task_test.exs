defmodule ExAtlas.Orchestrator.LambdaLabsTaskTest do
  # The orchestrator on Lambda through Bypass: run_task/1 ended by the host's
  # finish report, and max_cost.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExAtlas.Test.FakeLambda

  alias ExAtlas.Callback
  alias ExAtlas.Orchestrator.Events
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
    :ok
  end

  defp subscribe(id), do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

  describe "run_task/1" do
    test "a finish report ends the task :completed and the tracker terminates the instance" do
      lambda = [provider: :lambda_labs] ++ start()

      opts =
        lambda ++
          [
            gpu: :h100,
            image: "ghcr.io/acme/trainer:latest",
            command: ["python", "train.py"],
            callback: "https://app.example.com/atlas/cb",
            finish_grace_ms: 50,
            status_poll_ms: 20
          ]

      # Prepared here, as the orchestrator would, to learn the task id the
      # host's report is bound to.
      {:ok, prepared} = Callback.prepare(opts)
      assert {:ok, pid, compute} = ExAtlas.Orchestrator.run_task(prepared)
      id = compute.id
      subscribe(id)
      ref = Process.monitor(pid)

      # Control: the instance exists before the report.
      assert {:ok, %{id: ^id}} = ExAtlas.get_compute(id, lambda)

      # What the host's unit POSTs once `docker wait atlas` returns 0.
      :ok = Callback.ingest(prepared[:callback].task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, lambda)
    end

    test "a non-zero exit ends the task {:failed, {:exit_code, n}} and terminates it" do
      lambda = [provider: :lambda_labs] ++ start()

      opts =
        lambda ++
          [
            gpu: :h100,
            image: "x",
            command: ["false"],
            callback: "https://app.example.com/atlas/cb",
            finish_grace_ms: 50
          ]

      {:ok, prepared} = Callback.prepare(opts)
      assert {:ok, pid, %{id: id}} = ExAtlas.Orchestrator.run_task(prepared)
      subscribe(id)
      ref = Process.monitor(pid)

      :ok = Callback.ingest(prepared[:callback].task_id, :finish, %{"exit_code" => 3})

      assert_receive {:atlas_compute, ^id, {:task, {:failed, {:exit_code, 3}}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, lambda)
    end

    test "without a callback, the default self_terminate is :validation and nothing launches" do
      bypass = Bypass.open()

      assert {:error, %ExAtlas.Error{kind: :validation}} =
               ExAtlas.Orchestrator.run_task(
                 provider: :lambda_labs,
                 api_key: "lambda-test-key",
                 base_url: "http://localhost:#{bypass.port}",
                 provider_opts: %{ssh_key_name: "deploy"},
                 gpu: :h100,
                 image: "x",
                 command: ["python", "train.py"]
               )

      # Bypass fails the test on any request: none reached Lambda.
      Bypass.down(bypass)
    end
  end

  describe "max_cost" do
    test "a $36/hour type and a 1-cent cap terminates the instance, with no billing read" do
      bypass = Bypass.open()
      test_pid = self()

      types = %{
        "gpu_8x_h100_sxm5" =>
          type_entry("gpu_8x_h100_sxm5", 3600, 8, "H100 (80 GB SXM5)", ["us-east-1"])
      }

      Bypass.stub(bypass, "GET", "/instance-types", &json(&1, 200, %{"data" => types}))

      Bypass.expect_once(bypass, "POST", "/instance-operations/launch", fn conn ->
        json(conn, 200, %{"data" => %{"instance_ids" => ["capped1"]}})
      end)

      Bypass.stub(bypass, "GET", "/instances/capped1", fn conn ->
        json(conn, 200, %{"data" => instance(%{"id" => "capped1"})})
      end)

      Bypass.expect_once(bypass, "POST", "/instance-operations/terminate", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:terminated, body["instance_ids"]})
        json(conn, 200, %{"data" => %{"terminated_instances" => []}})
      end)

      # Before the spawn, so an event from the first tick is not missed.
      subscribe("capped1")

      assert {:ok, pid, %{id: "capped1", cost_per_hour: 36.0}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :lambda_labs,
                 api_key: "lambda-test-key",
                 base_url: "http://localhost:#{bypass.port}",
                 provider_opts: %{ssh_key_name: "deploy"},
                 gpu: :h100_sxm,
                 gpu_count: 8,
                 image: "x",
                 max_cost: 0.01,
                 reconcile_spend_ms: 10
               )

      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, "capped1", {:terminating, :cost_cap}}, 5_000
      assert_receive {:terminated, ["capped1"]}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      # Lambda has no billing API: the reconcile stops without a read or an
      # error event.
      refute_received {:atlas_compute, "capped1", {:spend_reconcile_failed, _}}
      refute_received {:atlas_compute, "capped1", {:spend_reconciled, _}}
    end
  end
end
