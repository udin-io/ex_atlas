defmodule ExAtlas.Callback.Limiter do
  @moduledoc """
  Per-task, per-kind token bucket for the inbound callback boundary.

  The callback endpoint is one the library *tells hosts to expose to the
  internet*, so "put a limiter in front of it" is not an adequate answer:
  the rate limit ships with the endpoint.

  One ETS-backed bucket per `{task_id, kind}` pair, sized from the budgets in
  `burst/1` and `rate_per_second/1`. Keying by `task_id` rather than by IP is
  what makes it useful — a pod's egress IP is the provider's, shared with every
  other tenant, and the task id is the only thing that identifies the caller
  we actually care about.

  ## Budgets

  | kind       | sustained | burst |
  |------------|-----------|-------|
  | `:progress`| 1/s       | 5     |
  | `:log`     | 6/min     | 20    |
  | `:finish`  | 1/min     | 3     |

  `:finish` is deliberately near-single-use: a task reports its exit code once,
  and the tracker stops shortly afterwards.

  ## Bounded memory

  Buckets are swept on a timer, so an attacker minting nothing (they cannot —
  a bucket is only created behind a verified token) and a host running millions
  of short tasks both leave a table sized by *recent* activity rather than by
  all activity. That, plus retaining no payload bytes anywhere, is why the
  boundary has no memory-exhaustion vector to tune.

  Started as part of the orchestrator supervision tree; `ExAtlas.Callback`
  needs `ExAtlas.Orchestrator.ComputeRegistry` anyway, so the two arrive
  together.
  """

  use GenServer

  alias ExAtlas.Callback.Token

  @table __MODULE__

  # {tokens per second, burst}
  @budgets %{
    progress: {1.0, 5},
    log: {0.1, 20},
    finish: {1 / 60, 3}
  }

  # Tokens are held as integer milli-tokens so the bucket needs no floats in
  # ETS and refill arithmetic stays exact.
  @scale 1_000

  @sweep_every_ms :timer.minutes(5)
  @idle_after_ms :timer.minutes(10)

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sustained refill rate, in requests per second, for `kind`."
  @spec rate_per_second(Token.kind()) :: float()
  def rate_per_second(kind), do: @budgets |> Map.fetch!(kind) |> elem(0)

  @doc "How many requests of `kind` a freshly-seen task may make back to back."
  @spec burst(Token.kind()) :: pos_integer()
  def burst(kind), do: @budgets |> Map.fetch!(kind) |> elem(1)

  @doc """
  Spend one token of `kind`'s budget for `task_id`.

  `:now_ms` overrides the clock; the refill is a function of elapsed monotonic
  time, so injecting it is what lets the budgets be tested without sleeping.
  """
  @spec take(Token.task_id(), Token.kind(), keyword()) :: :ok | {:error, :rate_limited}
  def take(task_id, kind, opts \\ []) do
    now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
    {rate, burst} = Map.fetch!(@budgets, kind)
    key = {task_id, kind}
    ceiling = burst * @scale

    {tokens, last} =
      case :ets.lookup(table!(), key) do
        [{^key, tokens, last}] -> {tokens, last}
        [] -> {ceiling, now}
      end

    available = min(ceiling, tokens + refill(now - last, rate))

    if available >= @scale do
      :ets.insert(@table, {key, available - @scale, now})
      :ok
    else
      :ets.insert(@table, {key, available, now})
      {:error, :rate_limited}
    end
  end

  @doc """
  Drop every bucket untouched for `@idle_after_ms`.

  Public so the sweep can be exercised without waiting five minutes for the
  timer; `now_ms` is the clock to sweep against.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now_ms \\ now_ms()) do
    cutoff = now_ms - @idle_after_ms
    :ets.select_delete(table!(), [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  # --- callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_every_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- helpers ---

  # Fail loud rather than open. A limiter that silently waves everything
  # through because nobody started it is worse than no limiter at all, because
  # the host believes it has one. Only reachable behind a verified token, so
  # this is not something an anonymous caller can provoke.
  defp table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} is not running. The pod callback boundary needs the " <>
                "orchestrator supervision tree: `config :ex_atlas, start_orchestrator: true`."

      _ref ->
        @table
    end
  end

  defp refill(elapsed_ms, _rate) when elapsed_ms <= 0, do: 0
  defp refill(elapsed_ms, rate), do: trunc(elapsed_ms * rate)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
