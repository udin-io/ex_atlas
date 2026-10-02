defmodule ExAtlas.Orchestrator.VastTaskTest do
  # The orchestrator on Vast through FakeVast: run_task/1 ended by the
  # container deleting its own instance, and max_cost.
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

  describe "max_cost" do
    # FakeVast's offer bills $0.42 an hour: a $0.0001 cap is spent in about a
    # second.
    test "a spent cap terminates the instance, with no billing read", %{vast: vast} do
      assert {:ok, pid, %{id: id, cost_per_hour: 0.42}} =
               ExAtlas.Orchestrator.run_task(
                 vast ++
                   [
                     gpu: :rtx_4090,
                     image: "pytorch/pytorch",
                     command: ["python", "train.py"],
                     max_cost: 0.0001,
                     reconcile_spend_ms: 10
                   ]
               )

      subscribe(id)
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 5_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute(id, vast)

      # Vast's spend read is slice 4: the reconcile stops without a read or an
      # error event.
      refute_received {:atlas_compute, ^id, {:spend_reconcile_failed, _}}
      refute_received {:atlas_compute, ^id, {:spend_reconciled, _}}
    end
  end
end
