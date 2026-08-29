defmodule ExAtlas.Orchestrator.UpstreamStatus do
  @moduledoc """
  Ask the provider whether a compute resource is still alive, and turn the
  answer into something a supervisor-friendly loop can act on.

  This is a plain module, not a process. Anything that needs to watch upstream
  state — `ExAtlas.Orchestrator.ComputeServer`'s status poller today, a
  readiness wait or a batch-task watchdog tomorrow — calls `observe/2` on its
  own schedule and decides what to do with the observation. Keeping the
  classification here means every caller agrees on what "dead" means instead of
  re-deriving it from `ExAtlas.Spec.Compute` statuses.

  ## Observations

    * `{:alive, compute}` — the resource exists and is provisioning or running.
    * `{:dead, reason, compute_or_nil}` — the resource will not serve traffic
      again. `compute` is `nil` when the provider no longer knows the id at
      all, which is the caller's cue that there is nothing left to terminate.
    * `{:poll_failed, error}` — **we could not tell.** Every error other than
      "not found" lands here: a 500, a rate limit, a socket failure, a
      malformed body, even a bad API key. Callers must treat this as "no news"
      and keep polling, because tearing a resource down on the strength of a
      failed request is how a provider hiccup turns into a killed GPU job.

  ## Death reasons

  | Reason        | Upstream state                                     |
  | ------------- | -------------------------------------------------- |
  | `:failed`     | the provider reports the resource as failed        |
  | `:stopped`    | the container/instance exited but still exists     |
  | `:terminated` | the resource was destroyed by someone              |
  | `:vanished`   | the provider 404s the id                           |
  | `:preempted`  | as above, for a `spot: true` resource — see below  |

  Pass `spot: true` (the same flag you passed to `ExAtlas.spawn_compute/1`) and
  a resource that stops, is terminated, or vanishes is reported as
  `:preempted`. No provider offers a "you were outbid" signal, so preemption is
  only ever inferred: an interruptible instance that disappeared without us
  asking it to was almost certainly reclaimed. `:failed` is deliberately *not*
  remapped — a crash-looping image looks the same on spot and on-demand, and
  respawning it would just crash-loop somewhere else.

  ## Polling cadence

  `next_interval_ms/3` supplies the schedule: a jittered base interval while
  things are fine, exponential backoff while the provider is failing. Jitter
  matters once a node tracks more than a handful of resources — spawned
  together, they would otherwise poll in lockstep and hammer the provider in
  bursts.

      iex> ms = ExAtlas.Orchestrator.UpstreamStatus.next_interval_ms(30_000, 0)
      iex> ms >= 27_000 and ms <= 33_000
      true
  """

  alias ExAtlas.Spec

  @default_jitter 0.1
  @default_max_backoff_factor 8

  @type dead_reason :: :failed | :stopped | :terminated | :vanished | :preempted

  @type observation ::
          {:alive, Spec.Compute.t()}
          | {:dead, dead_reason(), Spec.Compute.t() | nil}
          | {:poll_failed, ExAtlas.Error.t() | term()}

  @doc """
  Fetch `id` from its provider and classify the result.

  `opts` are the spawn opts: they are passed through to `ExAtlas.get_compute/2`
  (so `:provider`, `:api_key`, `:base_url` and friends all work) and `:spot` is
  read to decide whether a disappearance counts as preemption.
  """
  @spec observe(String.t(), keyword()) :: observation()
  def observe(id, opts \\ []) when is_binary(id) do
    id |> ExAtlas.get_compute(opts) |> classify(Keyword.get(opts, :spot, false))
  end

  @doc """
  Classify an already-fetched `ExAtlas.get_compute/2` result.

  Exposed so a caller that already holds a fresh `Compute` (a spawn response, a
  `list_compute/1` page) can reuse the same vocabulary without a second request.
  """
  @spec classify({:ok, Spec.Compute.t()} | {:error, term()}, boolean()) :: observation()
  def classify(result, spot? \\ false)

  def classify({:ok, %Spec.Compute{status: status} = compute}, _spot?)
      when status in [:provisioning, :running],
      do: {:alive, compute}

  def classify({:ok, %Spec.Compute{status: :failed} = compute}, _spot?),
    do: {:dead, :failed, compute}

  def classify({:ok, %Spec.Compute{status: status} = compute}, spot?)
      when status in [:stopped, :terminated],
      do: {:dead, if(spot?, do: :preempted, else: status), compute}

  def classify({:error, %ExAtlas.Error{kind: :not_found}}, spot?),
    do: {:dead, if(spot?, do: :preempted, else: :vanished), nil}

  def classify({:error, error}, _spot?), do: {:poll_failed, error}

  @doc """
  Milliseconds to wait before the next poll.

  Returns `base_ms` jittered by ±`:jitter` (a fraction, default `0.1`) while
  `consecutive_failures` is zero, and doubles per failure after that, capped at
  `:max_ms` (default eight times the base).

      next_interval_ms(30_000, 0)                  # ≈ 30s
      next_interval_ms(30_000, 3, jitter: 0.0)     # 240s
  """
  @spec next_interval_ms(pos_integer(), non_neg_integer(), keyword()) :: pos_integer()
  def next_interval_ms(base_ms, consecutive_failures, opts \\ [])
      when is_integer(base_ms) and base_ms > 0 and consecutive_failures >= 0 do
    max_ms = Keyword.get(opts, :max_ms, base_ms * @default_max_backoff_factor)
    jitter = Keyword.get(opts, :jitter, @default_jitter)

    base_ms
    |> backoff(consecutive_failures, max_ms)
    |> jitter(jitter)
    |> max(1)
  end

  # `consecutive_failures` is unbounded in principle; shifting by it directly
  # would build a bignum before the cap is applied, so clamp the exponent first.
  defp backoff(base_ms, failures, max_ms) do
    exponent = min(failures, ceil(:math.log2(max(max_ms, 1)) + 1))

    base_ms
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(max_ms)
    |> max(base_ms)
  end

  defp jitter(ms, fraction) when fraction <= 0, do: ms

  defp jitter(ms, fraction) do
    spread = round(ms * fraction)
    ms - spread + :rand.uniform(2 * spread + 1) - 1
  end
end
