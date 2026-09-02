defmodule ExAtlas.Orchestrator.TaskOutcomeTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Orchestrator.TaskOutcome
  alias ExAtlas.Spec

  doctest ExAtlas.Orchestrator.TaskOutcome

  defp compute(status),
    do: %Spec.Compute{id: "c1", provider: :mock, status: status}

  describe "classify/2 in :interactive mode" do
    test "never reports a task outcome, whatever the observation" do
      for observation <- [
            {:alive, compute(:running)},
            {:poll_failed, :timeout},
            {:dead, :vanished, nil},
            {:dead, :failed, compute(:failed)},
            {:dead, :preempted, nil}
          ] do
        assert TaskOutcome.classify(observation, :interactive) == :none
      end
    end
  end

  describe "classify/2 in :task mode" do
    test "a live resource is not an outcome" do
      assert TaskOutcome.classify({:alive, compute(:running)}, :task) == :none
      assert TaskOutcome.classify({:alive, compute(:provisioning)}, :task) == :none
    end

    test "a failed poll is not an outcome — we could not tell anything" do
      assert TaskOutcome.classify({:poll_failed, :timeout}, :task) == :none

      assert TaskOutcome.classify({:poll_failed, %ExAtlas.Error{kind: :provider}}, :task) ==
               :none
    end

    test "a resource the provider has forgotten completed: it self-terminated" do
      assert TaskOutcome.classify({:dead, :vanished, nil}, :task) == :completed
    end

    test "a resource whose container exited completed too" do
      assert TaskOutcome.classify({:dead, :stopped, compute(:stopped)}, :task) == :completed
    end

    test "a resource destroyed by someone else did not complete" do
      assert TaskOutcome.classify({:dead, :terminated, compute(:terminated)}, :task) ==
               {:failed, :terminated}
    end

    test "a preempted resource carries its cause" do
      assert TaskOutcome.classify({:dead, :preempted, nil}, :task) == {:failed, :preempted}
    end

    test "a provider-reported failure carries its cause" do
      assert TaskOutcome.classify({:dead, :failed, compute(:failed)}, :task) ==
               {:failed, :failed}
    end
  end

  describe "classify/3 with no report" do
    test "is byte-identical to classify/2 — a host with no callback loses nothing" do
      for observation <- [
            {:alive, compute(:running)},
            {:poll_failed, :timeout},
            {:dead, :vanished, nil},
            {:dead, :stopped, compute(:stopped)},
            {:dead, :terminated, compute(:terminated)},
            {:dead, :preempted, nil},
            {:dead, :failed, compute(:failed)}
          ],
          mode <- [:interactive, :task] do
        assert TaskOutcome.classify(observation, mode, nil) ==
                 TaskOutcome.classify(observation, mode)
      end
    end
  end

  describe "classify/3 with a finish report" do
    test "a clean exit turns an inferred completion into a proven one" do
      assert TaskOutcome.classify({:dead, :vanished, nil}, :task, %{exit_code: 0}) == :completed
    end

    test "a non-zero exit becomes a failure with the code" do
      assert TaskOutcome.classify({:dead, :vanished, nil}, :task, %{exit_code: 3}) ==
               {:failed, {:exit_code, 3}}
    end

    test "a preempted spot pod that reported a clean exit completed — this is the spot fix" do
      assert TaskOutcome.classify({:dead, :preempted, nil}, :task, %{exit_code: 0}) == :completed
    end

    test "a preempted spot pod that reported a failure carries the exit code, not the preemption" do
      assert TaskOutcome.classify({:dead, :preempted, nil}, :task, %{exit_code: 1}) ==
               {:failed, {:exit_code, 1}}
    end

    test "a report cannot conjure an outcome from an observation that ends nothing" do
      assert TaskOutcome.classify({:alive, compute(:running)}, :task, %{exit_code: 0}) == :none
      assert TaskOutcome.classify({:poll_failed, :timeout}, :task, %{exit_code: 0}) == :none
    end

    test "interactive mode still has no task to end" do
      assert TaskOutcome.classify({:dead, :vanished, nil}, :interactive, %{exit_code: 0}) == :none
    end
  end

  describe "from_report/1" do
    test "reads an outcome from the report alone, for the grace timer" do
      assert TaskOutcome.from_report(%{exit_code: 0}) == :completed
      assert TaskOutcome.from_report(%{exit_code: 137}) == {:failed, {:exit_code, 137}}
    end
  end
end
