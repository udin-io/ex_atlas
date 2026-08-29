defmodule ExAtlas.Orchestrator.ComputeServer do
  @moduledoc """
  One `GenServer` per tracked compute resource.

  Responsibilities:

    * Hold the resource's normalized `ExAtlas.Spec.Compute`, its `:user_id`,
      `:idle_ttl_ms`, last-activity timestamp, and spawn opts.
    * Trap exits so `terminate/2` always calls `ExAtlas.terminate/2` on the
      upstream provider — even on supervisor shutdown or crash.
    * Drive its own idle reaper: every `:heartbeat_ms` it compares
      `:last_activity_ms` against `:idle_ttl_ms`, and stops (terminating the
      upstream resource) once the session has gone quiet.
    * Poll the provider every `:status_poll_ms` so the resource dying on the
      cloud's side — host failure, crash-looping image, spot preemption — is
      noticed rather than assumed away.
    * Broadcast state changes over `Phoenix.PubSub` via
      `ExAtlas.Orchestrator.Events`.

  ## Two independent clocks

  The heartbeat answers "does anyone still want this?" and the status poll
  answers "is it still there?". They are deliberately separate timers: the
  first is paced by your users' activity, the second by what your provider's
  API will tolerate. Set `status_poll_ms: false` to opt out of upstream polling
  entirely.

  ## Reacting to upstream death

  A poll that comes back dead broadcasts the cause (`{:status, :preempted}`,
  `{:status, :failed}`, …) and then stops the server normally. A poll that
  merely *fails* — 5xx, rate limit, socket error — broadcasts
  `{:poll_failed, error}`, backs the next poll off exponentially, and changes
  nothing else. Tearing a live GPU down because one request to the provider
  failed would be far more expensive than noticing its death a minute late.

  With `on_failure: {:respawn, max_attempts}` the server replaces a *preempted*
  resource instead of stopping: it spawns a fresh one from the same opts,
  re-keys itself in the registry under the new id, and broadcasts
  `{:respawned, compute}` on the old topic so subscribers can follow. That
  suits checkpoint-based batch work on spot capacity.

  Preemption is the only cause worth retrying, and the option is narrow on
  purpose. A resource that was stopped or terminated was ended by someone; an
  image that `:failed` on this host will fail on the next one, so respawning it
  just crash-loops on a meter.

  Per project conventions, callback bodies never wrap logic in `try/rescue` —
  if a provider API raises, we let the server crash and the supervisor
  handles restart policy. The `terminate/2` callback handles upstream teardown.
  """

  use GenServer

  alias ExAtlas.Orchestrator.{ComputeRegistry, Events, UpstreamStatus}

  @default_idle_ttl_ms 30 * 60 * 1_000
  @default_heartbeat_interval_ms 60 * 1_000

  # RunPod's management API publishes no rate limits at all, so the default is
  # deliberately unhurried: one request per resource per minute is cheap for
  # the provider and still bounds wasted spend to roughly a minute, which is
  # the same window the Reaper already works on.
  @default_status_poll_ms 60 * 1_000

  # The only death we can both identify and usefully retry. See the moduledoc.
  @respawnable [:preempted]

  # The tracking options, as opposed to the `ExAtlas.Spec.ComputeRequest` and
  # provider-config options that share the same keyword list. Validated at the
  # `ExAtlas.Orchestrator.spawn/1` boundary — *before* the provider is asked to
  # rent anything — so a typo can never leave a live resource behind an
  # `init/1` that refuses to start.
  @schema [
    idle_ttl_ms: [type: :pos_integer, default: @default_idle_ttl_ms],
    heartbeat_ms: [type: :pos_integer, default: @default_heartbeat_interval_ms],
    status_poll_ms: [
      type: {:or, [:pos_integer, {:in, [false]}]},
      default: @default_status_poll_ms
    ],
    on_failure: [
      type: {:or, [{:in, [:stop]}, {:tuple, [{:in, [:respawn]}, :non_neg_integer]}]},
      default: :stop
    ],
    user_id: [type: :any, default: nil]
  ]

  @option_keys Keyword.keys(@schema)

  @type state :: %{
          compute: ExAtlas.Spec.Compute.t(),
          opts: keyword(),
          idle_ttl_ms: pos_integer(),
          heartbeat_ms: pos_integer(),
          status_poll_ms: pos_integer() | nil,
          poll_failures: non_neg_integer(),
          upstream_present?: boolean(),
          respawn_limit: non_neg_integer(),
          respawns: non_neg_integer(),
          last_activity_ms: integer(),
          user_id: term() | nil
        }

  @doc false
  def start_link({compute, opts}) do
    name = {:via, Registry, {ComputeRegistry, {:compute, compute.id}}}
    GenServer.start_link(__MODULE__, {compute, opts}, name: name)
  end

  def child_spec({compute, opts}) do
    %{
      id: {:compute_server, compute.id},
      start: {__MODULE__, :start_link, [{compute, opts}]},
      restart: :transient,
      type: :worker
    }
  end

  @doc """
  Validate the tracking options out of a spawn keyword list.

  `ExAtlas.Orchestrator.spawn/1` calls this before the provider call so a bad
  `:status_poll_ms` or a mistyped `:on_failure` is a plain `{:error, _}` rather
  than an `init/1` crash on top of a resource that is already running (and
  billing) upstream. Keys that belong to `ExAtlas.Spec.ComputeRequest` or to
  the provider config are ignored here — each is validated by its own owner.
  """
  @spec validate_opts(keyword()) ::
          {:ok, keyword()} | {:error, NimbleOptions.ValidationError.t()}
  def validate_opts(opts) do
    opts |> Keyword.take(@option_keys) |> NimbleOptions.validate(@schema)
  end

  @doc "Bump last-activity so the idle reaper waits another `idle_ttl_ms`."
  def touch(pid), do: GenServer.cast(pid, :touch)

  @doc "Return the current tracked state."
  def info(pid), do: GenServer.call(pid, :info)

  # --- callbacks ---

  @impl true
  def init({compute, opts}) do
    Process.flag(:trap_exit, true)

    # Already validated by `ExAtlas.Orchestrator.spawn/1`; re-run so a directly
    # started tracker gets the same defaults and the same clear failure.
    tracking = NimbleOptions.validate!(Keyword.take(opts, @option_keys), @schema)

    state = %{
      compute: compute,
      opts: opts,
      idle_ttl_ms: tracking[:idle_ttl_ms],
      heartbeat_ms: tracking[:heartbeat_ms],
      status_poll_ms: poll_interval(tracking[:status_poll_ms]),
      poll_failures: 0,
      upstream_present?: true,
      respawn_limit: respawn_limit(tracking[:on_failure]),
      respawns: 0,
      last_activity_ms: now_ms(),
      user_id: tracking[:user_id]
    }

    Events.broadcast(compute.id, {:status, compute.status})
    schedule_heartbeat(state.heartbeat_ms)
    schedule_status_poll(state)
    {:ok, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_activity_ms: now_ms()}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:compute, :last_activity_ms, :user_id, :idle_ttl_ms]), state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    idle_for = now_ms() - state.last_activity_ms

    if idle_for >= state.idle_ttl_ms do
      Events.broadcast(state.compute.id, {:terminating, :idle_timeout})
      {:stop, :normal, state}
    else
      Events.broadcast(state.compute.id, {:heartbeat, now_ms()})
      schedule_heartbeat(state.heartbeat_ms)
      {:noreply, state}
    end
  end

  def handle_info(:status_poll, state) do
    state.compute.id
    |> UpstreamStatus.observe(state.opts)
    |> apply_observation(state)
  end

  @impl true
  def terminate(reason, state) do
    Events.broadcast(state.compute.id, {:terminating, reason})

    if state.upstream_present? do
      terminate_upstream(state)
    else
      # The provider has already forgotten this resource — a DELETE would only
      # earn us a 404 and a misleading `{:terminate_failed, _}`.
      Events.broadcast(state.compute.id, {:status, :terminated})
    end

    :ok
  end

  # --- observations ---

  defp apply_observation({:alive, upstream}, state) do
    state = state |> refresh_compute(upstream) |> Map.put(:poll_failures, 0)
    schedule_status_poll(state)
    {:noreply, state}
  end

  defp apply_observation({:poll_failed, error}, state) do
    Events.broadcast(state.compute.id, {:poll_failed, error})
    state = Map.update!(state, :poll_failures, &(&1 + 1))
    schedule_status_poll(state)
    {:noreply, state}
  end

  defp apply_observation({:dead, reason, upstream}, state) do
    Events.broadcast(state.compute.id, {:status, reason})
    state = %{state | upstream_present?: not is_nil(upstream)}

    if respawn?(reason, state) do
      respawn(state, reason)
    else
      {:stop, :normal, state}
    end
  end

  # `get_compute/2` can't return the auth handle — it was minted locally at
  # spawn and never left this node — so carry it across every refresh.
  defp refresh_compute(state, upstream) do
    upstream = %{upstream | auth: state.compute.auth}

    if upstream.status != state.compute.status do
      Events.broadcast(state.compute.id, {:status, upstream.status})
    end

    %{state | compute: upstream}
  end

  # --- respawn ---

  defp respawn?(reason, state),
    do: reason in @respawnable and state.respawns < state.respawn_limit

  defp respawn(state, reason) do
    old_id = state.compute.id

    case ExAtlas.spawn_compute(state.opts) do
      {:ok, replacement} ->
        :ok = Registry.unregister(ComputeRegistry, {:compute, old_id})
        {:ok, _} = Registry.register(ComputeRegistry, {:compute, replacement.id}, nil)

        Events.broadcast(old_id, {:respawned, replacement})
        Events.broadcast(replacement.id, {:status, replacement.status})

        state = %{
          state
          | compute: replacement,
            respawns: state.respawns + 1,
            poll_failures: 0,
            upstream_present?: true,
            last_activity_ms: now_ms()
        }

        schedule_status_poll(state)
        {:noreply, state}

      {:error, error} ->
        Events.broadcast(old_id, {:respawn_failed, {reason, error}})
        {:stop, :normal, state}
    end
  end

  # --- teardown ---

  defp terminate_upstream(state) do
    case ExAtlas.terminate(state.compute.id, state.opts) do
      :ok -> Events.broadcast(state.compute.id, {:status, :terminated})
      {:error, err} -> Events.broadcast(state.compute.id, {:terminate_failed, err})
    end
  end

  # --- scheduling ---

  defp schedule_heartbeat(ms), do: Process.send_after(self(), :heartbeat, ms)

  defp schedule_status_poll(%{status_poll_ms: nil}), do: :ok

  defp schedule_status_poll(%{status_poll_ms: base, poll_failures: failures}) do
    Process.send_after(self(), :status_poll, UpstreamStatus.next_interval_ms(base, failures))
  end

  # --- opts ---

  defp poll_interval(false), do: nil
  defp poll_interval(ms) when is_integer(ms) and ms > 0, do: ms

  defp respawn_limit(:stop), do: 0
  defp respawn_limit({:respawn, max}), do: max

  defp now_ms, do: System.monotonic_time(:millisecond)
end
