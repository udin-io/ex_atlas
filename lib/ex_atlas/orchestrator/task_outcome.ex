defmodule ExAtlas.Orchestrator.TaskOutcome do
  @moduledoc """
  Turn an upstream observation into the outcome of a batch task — or into
  nothing at all, which is the usual answer.

  Like `ExAtlas.Orchestrator.UpstreamStatus`, this is a plain module rather
  than a process. It exists so that the one genuinely mode-dependent decision
  in `ExAtlas.Orchestrator.ComputeServer` — "does this observation end the
  task, and how?" — can be read, reasoned about and tested without a
  supervision tree, leaving the GenServer with one extra timer and one extra
  branch instead of a second personality.

  ## Modes

    * `:interactive` (the default everywhere) — there is no task, so there is
      never an outcome. `classify/2` returns `:none` for every observation.
    * `:task` — the resource was rented to run a command to completion.

  ## Outcomes

    * `:completed` — **the container ended and the resource is gone.** Read
      that literally: it does *not* mean the work succeeded. The
      self-termination wrapper traps `EXIT`, so a crashed command cleans up
      exactly like a successful one, and both reach us as the same 404. The
      exit code dies with the pod — RunPod's REST API offers no way to read it
      back. A real success/failure signal needs the container to report it
      before it goes, which is a separate piece of work.
    * `:timed_out` — the `:max_runtime_ms` deadline fired. Not produced here;
      the deadline is a local clock, not an observation.
    * `{:failed, reason}` — the resource died of something that is not the
      task finishing. `reason` is the death reason `UpstreamStatus` reported
      (`:preempted`, `:terminated`, `:failed`), or `:never_ready` when the
      resource never left `:provisioning` within `:ready_timeout_ms`.

  ## Why "we could not tell" is never an outcome

  `{:poll_failed, _}` — a 5xx, a rate limit, a socket error, a bad key —
  returns `:none`, so the poller backs off and the task keeps running. A
  90-minute unattended run will meet a provider hiccup; ending it on one would
  throw away the whole run and the money spent on it.
  """

  alias ExAtlas.Orchestrator.UpstreamStatus

  @type mode :: :interactive | :task

  @type failure_reason :: UpstreamStatus.dead_reason() | :never_ready

  @type t :: :completed | :timed_out | {:failed, failure_reason()}

  @doc """
  Classify an `ExAtlas.Orchestrator.UpstreamStatus` observation for `mode`.

  Returns `:none` when the observation does not end the task, which covers
  every observation in `:interactive` mode and the great majority in `:task`
  mode.

      iex> alias ExAtlas.Orchestrator.TaskOutcome
      iex> TaskOutcome.classify({:dead, :vanished, nil}, :task)
      :completed
      iex> TaskOutcome.classify({:dead, :vanished, nil}, :interactive)
      :none
  """
  @spec classify(UpstreamStatus.observation(), mode()) :: t() | :none
  def classify(_observation, :interactive), do: :none

  def classify({:dead, reason, _upstream}, :task), do: outcome(reason)

  # `{:alive, _}` and `{:poll_failed, _}`: still running, or unknowable.
  def classify(_observation, :task), do: :none

  # A resource the provider has forgotten is the self-termination wrapper
  # having done its job: the container ended and deleted the pod. A resource
  # the provider still holds but reports as stopped is the same ending seen
  # through a provider that keeps its records.
  defp outcome(:vanished), do: :completed
  defp outcome(:stopped), do: :completed

  # Everything else ended the resource without the task finishing: someone
  # destroyed it, the spot capacity was reclaimed, or the provider called it
  # failed.
  defp outcome(reason), do: {:failed, reason}
end
