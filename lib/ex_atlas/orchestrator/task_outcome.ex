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

    * `:completed` — the container ended and the resource is gone. Without a
      finish report that is *inferred*, and it does not mean the work
      succeeded: the self-termination wrapper traps `EXIT`, so a crashed
      command cleans up exactly like a successful one and both reach us as the
      same 404. **With** a report it is proven — see below.
    * `:timed_out` — the `:max_runtime_ms` deadline fired. Not produced here;
      the deadline is a local clock, not an observation.
    * `{:failed, reason}` — the resource died of something that is not the
      task finishing. `reason` is the death reason `UpstreamStatus` reported
      (`:preempted`, `:terminated`, `:failed`), `:never_ready` when the
      resource never left `:provisioning` within `:ready_timeout_ms`, or
      `{:exit_code, n}` when the container reported a non-zero exit.

  ## What a finish report changes

  `ExAtlas.Callback` gives a container a way to POST its exit code *before* it
  self-terminates. When one arrives, `ExAtlas.Orchestrator.ComputeServer` hands
  it here as the third argument, and it becomes authoritative for any
  observation that ends the resource:

      classify({:dead, :vanished, _},  :task, nil)              #=> :completed  (inferred)
      classify({:dead, :vanished, _},  :task, %{exit_code: 0})  #=> :completed  (proven)
      classify({:dead, :vanished, _},  :task, %{exit_code: 3})  #=> {:failed, {:exit_code, 3}}
      classify({:dead, :preempted, _}, :task, %{exit_code: 0})  #=> :completed

  That last line is the spot fix. Today a 404 on spot capacity means both
  "self-terminated fine" and "reclaimed by the provider", so `on_failure:
  {:respawn, n}` can re-run work that already finished. A report is a marker
  written before the pod goes, so the disappearance is no longer ambiguous.

  The honest limit: a pod preempted in the milliseconds *between* the POST and
  its own `DELETE` still reads as completed. The work genuinely did finish, so
  that is the right error to make. A pod preempted before the POST is still
  correctly a preemption.

  Non-zero exits map onto the existing `{:failed, reason}` shape rather than a
  new event shape, so no subscriber breaks.

  ## Why "we could not tell" is never an outcome

  `{:poll_failed, _}` — a 5xx, a rate limit, a socket error, a bad key —
  returns `:none`, so the poller backs off and the task keeps running. A
  90-minute unattended run will meet a provider hiccup; ending it on one would
  throw away the whole run and the money spent on it.
  """

  alias ExAtlas.Orchestrator.UpstreamStatus

  @type mode :: :interactive | :task

  @type failure_reason ::
          UpstreamStatus.dead_reason() | :never_ready | {:exit_code, pos_integer()}

  @type t :: :completed | :timed_out | {:failed, failure_reason()}

  @typedoc "What the container said about its own ending, if it said anything."
  @type report :: %{exit_code: non_neg_integer()} | nil

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
      iex> TaskOutcome.classify({:dead, :preempted, nil}, :task, %{exit_code: 0})
      :completed
  """
  @spec classify(UpstreamStatus.observation(), mode(), report()) :: t() | :none
  def classify(observation, mode, report \\ nil)

  def classify(_observation, :interactive, _report), do: :none

  def classify({:dead, reason, _upstream}, :task, report), do: outcome(reason, report)

  # `{:alive, _}` and `{:poll_failed, _}`: still running, or unknowable. A
  # report cannot change that — the task is not over until something says the
  # resource is gone or a local clock fires.
  def classify(_observation, :task, _report), do: :none

  @doc """
  The outcome implied by a finish report alone.

  Used by the `:finish_grace_ms` timer, for the case where the report arrived
  but the pod never disappeared — `self_terminate: false`, a trap that was
  skipped, a `DELETE` that failed. There is no observation to classify there;
  the report is all there is.
  """
  @spec from_report(%{exit_code: non_neg_integer()}) :: t()
  def from_report(%{exit_code: 0}), do: :completed
  def from_report(%{exit_code: code}), do: {:failed, {:exit_code, code}}

  # A report is a marker the container wrote before it went, so when one
  # exists it is a better account of the ending than anything inferred from the
  # resource's disappearance — including on spot capacity, where the
  # disappearance itself is ambiguous.
  defp outcome(_reason, %{exit_code: _} = report), do: from_report(report)

  # A resource the provider has forgotten is the self-termination wrapper
  # having done its job: the container ended and deleted the pod. A resource
  # the provider still holds but reports as stopped is the same ending seen
  # through a provider that keeps its records.
  defp outcome(:vanished, nil), do: :completed
  defp outcome(:stopped, nil), do: :completed

  # Everything else ended the resource without the task finishing: someone
  # destroyed it, the spot capacity was reclaimed, or the provider called it
  # failed.
  defp outcome(reason, nil), do: {:failed, reason}
end
