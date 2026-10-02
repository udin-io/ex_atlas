defmodule ExAtlas.Orchestrator.LambdaLabsTaskTest do
  # The orchestrator on Lambda through Bypass: run_task/1 ended by the host's
  # finish report, the Reaper, and max_cost.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExAtlas.Test.FakeLambda

  alias ExAtlas.Callback
  alias ExAtlas.Orchestrator.{Events, Reaper}
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

  describe "an interactive session with a command" do
    test "a finish report ends the session and the tracker terminates the instance" do
      lambda = [provider: :lambda_labs] ++ start()

      opts =
        lambda ++
          [
            gpu: :h100,
            image: "ghcr.io/acme/server:latest",
            command: ["python", "serve_once.py"],
            callback: "https://app.example.com/atlas/cb",
            finish_grace_ms: 50,
            status_poll_ms: 20
          ]

      {:ok, prepared} = Callback.prepare(opts)
      assert {:ok, pid, %{id: id}} = ExAtlas.Orchestrator.spawn(prepared)
      subscribe(id)
      ref = Process.monitor(pid)

      assert {:ok, %{id: ^id}} = ExAtlas.get_compute(id, lambda)

      :ok = Callback.ingest(prepared[:callback].task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :finished}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      refute_received {:atlas_compute, ^id, {:task, _}}

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, lambda)
    end
  end

  describe "Reaper" do
    setup do
      bypass = Bypass.open()
      previous = Application.get_env(:ex_atlas, :lambda_labs)

      Application.put_env(:ex_atlas, :lambda_labs,
        api_key: "lambda-test-key",
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_atlas, :lambda_labs, previous),
          else: Application.delete_env(:ex_atlas, :lambda_labs)
      end)

      {:ok, bypass: bypass}
    end

    test "deletes an untracked atlas- instance past the grace window, leaves a younger one", %{
      bypass: bypass
    } do
      TestOrchestrator.put_env(reap_grace_ms: 60 * 60 * 1_000)
      now = DateTime.utc_now()
      old = now |> DateTime.add(-2, :hour) |> DateTime.to_iso8601()
      young = now |> DateTime.add(-5, :minute) |> DateTime.to_iso8601()

      instances = [
        instance(%{"id" => "old1", "name" => "atlas-old", "tags" => created_at(old)}),
        instance(%{"id" => "young1", "name" => "atlas-young", "tags" => created_at(young)})
      ]

      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        json(conn, 200, %{"data" => instances, "page_token" => nil})
      end)

      test_pid = self()
      no_rulesets(bypass)

      Bypass.expect_once(bypass, "POST", "/instance-operations/terminate", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:terminated, body["instance_ids"]})
        json(conn, 200, %{"data" => %{"terminated_instances" => []}})
      end)

      :ok = Reaper.reap_now("atlas-", [:lambda_labs])

      assert_received {:terminated, ["old1"]}
      refute_received {:terminated, _}
    end
  end

  describe "Reaper and a created-at tag in the future" do
    setup do
      bypass = Bypass.open()
      previous = Application.get_env(:ex_atlas, :lambda_labs)

      Application.put_env(:ex_atlas, :lambda_labs,
        api_key: "lambda-test-key",
        base_url: "http://localhost:#{bypass.port}"
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_atlas, :lambda_labs, previous),
          else: Application.delete_env(:ex_atlas, :lambda_labs)
      end)

      {:ok, bypass: bypass}
    end

    # Anyone on the Lambda account can edit a tag. A far-future one must not
    # keep an orphan "young", and so billing, for ever.
    test "reaps an instance tagged a year ahead, leaves one a minute ahead", %{bypass: bypass} do
      TestOrchestrator.put_env(reap_grace_ms: 60 * 60 * 1_000)
      now = DateTime.utc_now()
      year = now |> DateTime.add(365, :day) |> DateTime.to_iso8601()
      # A launching node's clock a minute ahead of this one.
      skewed = now |> DateTime.add(1, :minute) |> DateTime.to_iso8601()

      instances = [
        instance(%{"id" => "future1", "name" => "atlas-future", "tags" => created_at(year)}),
        instance(%{"id" => "skewed1", "name" => "atlas-skewed", "tags" => created_at(skewed)})
      ]

      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        json(conn, 200, %{"data" => instances, "page_token" => nil})
      end)

      test_pid = self()
      no_rulesets(bypass)

      Bypass.expect_once(bypass, "POST", "/instance-operations/terminate", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:terminated, body["instance_ids"]})
        json(conn, 200, %{"data" => %{"terminated_instances" => []}})
      end)

      :ok = Reaper.reap_now("atlas-", [:lambda_labs])

      assert_received {:terminated, ["future1"]}
      refute_received {:terminated, _}
    end
  end

  describe "max_cost" do
    test "a $36/hour type and a 1-cent cap terminates the instance, with no billing read" do
      bypass = Bypass.open()
      test_pid = self()
      no_rulesets(bypass)

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

  defp created_at(at), do: [%{"key" => "atlas-created-at", "value" => at}]

  # `terminate/2` looks up the instance's firewall ruleset first (#86).
  defp no_rulesets(bypass),
    do: Bypass.stub(bypass, "GET", "/firewall-rulesets", &json(&1, 200, %{"data" => []}))
end
