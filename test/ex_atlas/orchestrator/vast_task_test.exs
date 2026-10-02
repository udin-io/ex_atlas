defmodule ExAtlas.Orchestrator.VastTaskTest do
  # The orchestrator on Vast through FakeVast: run_task/1 ended by the
  # container deleting its own instance, max_cost (the estimate and the charges bill), and an outbid spot
  # instance replaced by a respawn.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExAtlas.Test.FakeVast

  alias ExAtlas.Callback
  alias ExAtlas.Orchestrator.Events
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
    {:ok, vast: [provider: :vast] ++ start()}
  end

  defp subscribe(id), do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

  # What the wrapper's trap sends from the container: a DELETE of its own
  # instance, with the instance's key.
  defp container_deletes_itself(vast, id) do
    {:ok, %{status: 200}} =
      Req.delete("#{vast[:base_url]}/api/v0/instances/#{id}/",
        auth: {:bearer, "container-api-key"},
        retry: false
      )
  end

  describe "run_task/1" do
    test "ends :completed once the instance deletes itself", %{vast: vast} do
      assert {:ok, pid, %{id: id}} =
               ExAtlas.Orchestrator.run_task(
                 vast ++
                   [
                     gpu: :rtx_4090,
                     image: "pytorch/pytorch",
                     command: ["python", "train.py"],
                     max_runtime_ms: :timer.hours(2),
                     status_poll_ms: 20
                   ]
               )

      subscribe(id)
      ref = Process.monitor(pid)

      # Control: the instance exists, and the task has not ended, before the
      # container deletes it.
      assert {:ok, %{id: ^id}} = ExAtlas.get_compute(id, vast)
      refute_receive {:atlas_compute, ^id, {:task, _}}, 100

      container_deletes_itself(vast, id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    test "a finish report before the delete ends the task with its exit code", %{vast: vast} do
      {:ok, prepared} =
        Callback.prepare(
          vast ++
            [
              gpu: :rtx_4090,
              image: "pytorch/pytorch",
              command: ["python", "train.py"],
              callback: "https://app.example.com/atlas/cb",
              status_poll_ms: 20
            ]
        )

      assert {:ok, pid, %{id: id}} = ExAtlas.Orchestrator.run_task(prepared)
      subscribe(id)
      ref = Process.monitor(pid)

      # The trap's order: the report first, then the delete.
      :ok = Callback.ingest(prepared[:callback].task_id, :finish, %{"exit_code" => 3})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 3}}}, 2_000
      container_deletes_itself(vast, id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, {:exit_code, 3}}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end
  end

  describe "spot: true" do
    defp spot_task(vast, extra) do
      {:ok, prepared} =
        Callback.prepare(
          vast ++
            [
              gpu: :rtx_4090,
              image: "pytorch/pytorch",
              command: ["python", "train.py"],
              callback: "https://app.example.com/atlas/cb",
              status_poll_ms: 20
            ] ++ extra
        )

      {prepared, ExAtlas.Orchestrator.run_task(prepared)}
    end

    test "an outbid instance is replaced, the old one destroyed, and the task completes", %{
      vast: vast
    } do
      {prepared, {:ok, pid, %{id: old_id, cost_per_hour: bid}}} =
        spot_task(vast, spot: true, on_failure: {:respawn, 1})

      subscribe(old_id)
      ref = Process.monitor(pid)

      # Control: the instance bills its bid and storage, exists, and is not
      # replaced before it is outbid.
      assert bid == 0.21
      assert {:ok, %{id: ^old_id}} = ExAtlas.get_compute(old_id, vast)
      refute_receive {:atlas_compute, ^old_id, {:respawned, _}}, 100

      :ok = outbid(vast, old_id)

      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      refute new_id == old_id
      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(old_id, vast)
      assert {:ok, %{id: ^new_id, cost_per_hour: 0.21}} = ExAtlas.get_compute(new_id, vast)

      subscribe(new_id)
      :ok = Callback.ingest(prepared[:callback].task_id, :finish, %{"exit_code" => 0})
      container_deletes_itself(vast, new_id)

      assert_receive {:atlas_compute, ^new_id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
    end

    test "an outbid instance with no respawn left ends the task :preempted", %{vast: vast} do
      {_prepared, {:ok, pid, %{id: id}}} = spot_task(vast, spot: true)
      subscribe(id)
      ref = Process.monitor(pid)

      :ok = outbid(vast, id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, :preempted}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end

    test "guard: an on-demand instance that exits is not respawned", %{vast: vast} do
      {_prepared, {:ok, pid, %{id: id}}} = spot_task(vast, on_failure: {:respawn, 1})
      subscribe(id)
      ref = Process.monitor(pid)

      :ok = outbid(vast, id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end
  end

  describe "max_cost" do
    # FakeVast's offer bills $0.42 an hour, so the estimate alone reaches a
    # $0.0001 cap in about a second. A $5 cap is out of its reach in a test:
    # only a bill read from the charges API can spend it.
    defp capped_task(vast, max_cost) do
      {:ok, pid, %{id: id}} =
        ExAtlas.Orchestrator.run_task(
          vast ++
            [
              gpu: :rtx_4090,
              image: "pytorch/pytorch",
              command: ["python", "train.py"],
              max_cost: max_cost,
              reconcile_spend_ms: 10
            ]
        )

      subscribe(id)
      {pid, id}
    end

    test "a spent cap terminates the instance on the estimate", %{vast: vast} do
      {pid, id} = capped_task(vast, 0.0001)
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, vast)
    end

    test "a bill above the cap terminates the instance, though the estimate is far under", %{
      vast: vast
    } do
      {pid, id} = capped_task(vast, 5.0)
      ref = Process.monitor(pid)

      # Control: before Vast bills anything the task runs on, and the reads
      # reconcile at zero.
      assert_receive {:atlas_compute, ^id, {:spend_reconciled, %{billed_usd: +0.0}}}, 2_000
      refute_received {:atlas_compute, ^id, {:terminating, :cost_cap}}

      :ok = bill(vast, id, 6.0)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, vast)
    end

    test "a bill under the cap raises the spend and leaves the instance running", %{vast: vast} do
      {_pid, id} = capped_task(vast, 5.0)
      :ok = bill(vast, id, 1.0)

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconciled, %{billed_usd: 1.0, spent_usd: spent}}},
                     2_000

      assert spent >= 1.0
      refute_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 200
      assert {:ok, %{id: ^id}} = ExAtlas.get_compute(id, vast)

      # The tracker polls FakeVast, which ends with this test.
      ExAtlas.Orchestrator.stop_tracked(id)
    end
  end
end
