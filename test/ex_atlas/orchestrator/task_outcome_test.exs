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
end
