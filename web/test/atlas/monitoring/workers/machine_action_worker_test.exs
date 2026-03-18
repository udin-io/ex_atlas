defmodule Atlas.Monitoring.Workers.MachineActionWorkerTest do
  use Atlas.DataCase, async: true

  alias Atlas.Monitoring.Workers.MachineActionWorker

  test "enqueue_start creates an Oban job" do
    assert {:ok, job} = MachineActionWorker.enqueue_start("some-uuid")
    assert job.args["action"] || job.args[:action] == "start"
    assert job.worker == "Atlas.Monitoring.Workers.MachineActionWorker"
  end

  test "enqueue_stop creates an Oban job" do
    assert {:ok, job} = MachineActionWorker.enqueue_stop("some-uuid")
    assert job.args["action"] || job.args[:action] == "stop"
  end
end
