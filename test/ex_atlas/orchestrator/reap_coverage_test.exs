defmodule ExAtlas.Orchestrator.ReapCoverageTest do
  # A node that dies while a respawn rents leaves the replacement running with
  # no record (risk 51). Only the Reaper deletes it, so a spawn that can
  # respawn on a provider outside `:reap_providers` warns.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator
  alias ExAtlas.Test.FakeVast
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
  end

  defp spawn_log(opts) do
    capture_log(fn ->
      assert {:ok, _pid, _compute} =
               Orchestrator.spawn(
                 [
                   provider: :mock,
                   gpu: :h100,
                   image: "trainer:latest",
                   name: "atlas-train",
                   status_poll_ms: false
                 ] ++ opts
               )
    end)
  end

  test "a respawning spawn on a provider outside :reap_providers warns, naming it" do
    TestOrchestrator.put_env(reap_providers: [:runpod])

    log = spawn_log(on_failure: {:respawn, 2})

    assert log =~ ~s("atlas-train")
    assert log =~ ":mock is not in :reap_providers"
  end

  test "a module in :reap_providers covers its atom" do
    TestOrchestrator.put_env(reap_providers: [ExAtlas.Providers.Mock])

    refute spawn_log(on_failure: {:respawn, 2}) =~ ":reap_providers"
  end

  test "control: no warning with the provider in :reap_providers" do
    TestOrchestrator.put_env(reap_providers: [:runpod, :mock])

    refute spawn_log(on_failure: {:respawn, 2}) =~ ":reap_providers"
  end

  test "control: no warning for a task that never respawns" do
    TestOrchestrator.put_env(reap_providers: [])

    refute spawn_log(on_failure: :stop) =~ ":reap_providers"
    refute spawn_log(on_failure: {:respawn, 0}) =~ ":reap_providers"
  end

  # `:vast` stays out of the default: its instance labels are free text, so
  # the `atlas-` marker can match an instance ExAtlas never rented.
  test "a respawning Vast spot task warns under the default :reap_providers" do
    vast = [provider: :vast] ++ FakeVast.start()

    log =
      capture_log(fn ->
        assert {:ok, _pid, %{id: id}} =
                 Orchestrator.run_task(
                   vast ++
                     [
                       gpu: :rtx_4090,
                       image: "pytorch/pytorch",
                       command: ["python", "train.py"],
                       name: "atlas-train",
                       spot: true,
                       on_failure: {:respawn, 1},
                       status_poll_ms: false
                     ]
                 )

        # The instance goes while FakeVast, which the test process owns, is
        # still up.
        :ok = Orchestrator.stop_tracked(id)
      end)

    assert log =~ ":vast is not in :reap_providers"
  end
end
