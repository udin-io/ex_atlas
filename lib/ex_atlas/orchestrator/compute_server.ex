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

  ## The poll never runs in the callback

  `get_compute/2` is an HTTP call against someone else's cloud, and the
  provider clients allow retries: a single RunPod poll can hold a process for
  around two minutes. So the poll runs in a task under
  `ExAtlas.Orchestrator.TaskSupervisor` and its result arrives as a message.
  Doing it inline parked the mailbox for the duration — `info/1` timed out,
  `touch/1` was silently delayed, and worst of all a teardown request queued
  behind the poll was brutal-killed by the supervisor's shutdown timer before
  `terminate/2` could issue the `DELETE`, leaving the resource billing with
  nothing left to reclaim it but the Reaper.

  An in-flight poll is killed on teardown, and a result that arrives after we
  stopped caring is ignored.

  ## Why a crashed tracker is not restarted

  The child spec is `restart: :temporary`. A restart replays the original
  `{compute, opts}`, and those go stale the moment anything moves: after a
  respawn the tracker holds a different id, and after any non-brutal crash
  `terminate/2` has already deleted the resource — so a restarted tracker
  polls something that no longer exists, and with `on_failure` its respawn
  budget is back to zero, letting it rent more replacements than
  `max_attempts` allows.

  Nothing is lost by not restarting: `terminate/2` runs on a crash and takes
  the resource with it, and a brutal kill (which skips `terminate/2`) leaves
  an orphan, which is precisely what `ExAtlas.Orchestrator.Reaper` exists to
  reclaim.

  ## Reacting to upstream death

  A poll that comes back dead broadcasts the cause (`{:status, :preempted}`,
  `{:status, :failed}`, …) and then stops the server normally. A poll that
  merely *fails* — 5xx, rate limit, socket error — broadcasts
  `{:poll_failed, error}`, backs the next poll off exponentially, and changes
  nothing else. Tearing a live GPU down because one request to the provider
  failed would be far more expensive than noticing its death a minute late.

  With `on_failure: {:respawn, max_attempts}` the server replaces a *preempted*
  resource instead of stopping: it spawns a fresh one from the same opts,
  terminates the old one if the provider still has it, re-keys itself in the
  registry under the new id, and broadcasts `{:respawned, new_id}` on the old
  topic so subscribers can follow. The event carries the id and nothing else:
  the replacement's `auth` handle holds a bearer token, and a PubSub topic is
  the wrong place for one. Subscribers read it back with
  `ExAtlas.Orchestrator.info/1`. That suits checkpoint-based batch work on spot
  capacity.

  Preemption is the only cause worth retrying, and the option is narrow on
  purpose. A resource that was stopped or terminated was ended by someone; an
  image that `:failed` on this host will fail on the next one, so respawning it
  just crash-loops on a meter.

  Per project conventions, callback bodies never wrap logic in `try/rescue`.
  The poll needs no rescue anyway: it runs in its own task, so a provider that
  raises — `Client.fetch_key!/1` on a key that resolves to nil, a translator
  on a body it cannot read — arrives here as a `:DOWN` and is reported as
  `{:poll_failed, reason}` like any other failure. That matters because this
  server traps exits: a raise in the callback would run `terminate/2` and
  DELETE a resource we never established was dead, which is the opposite of
  the rule above. For the same reason `handle_info/2` has a catch-all, so a
  stray message cannot destroy a live resource either.
  """

  use GenServer

  alias ExAtlas.Orchestrator.{ComputeRegistry, Events, UpstreamStatus}
  alias ExAtlas.Spec

  @task_supervisor ExAtlas.Orchestrator.TaskSupervisor

  @default_idle_ttl_ms 30 * 60 * 1_000
  @default_heartbeat_interval_ms 60 * 1_000

  # RunPod's management API publishes no rate limits at all, so the default is
  # deliberately unhurried: one request per resource per minute is cheap for
  # the provider and still bounds wasted spend to roughly a minute, which is
  # the same window the Reaper already works on.
  @default_status_poll_ms 60 * 1_000

  # The only death we can both identify and usefully retry. See the moduledoc.
  @respawnable [:preempted]

  # A poll is a background health check, not a user-facing request. The
  # provider clients are tuned for the latter — RunPod's is 30s per attempt
  # with three transient retries — which is far too long to leave a poll
  # outstanding when the answer is only ever "still there?".
  @poll_req_options [receive_timeout: 5_000, retry: false]

  # Backstop for a poll that ignores its own timeout (a wedged connect, a
  # provider module that blocks). Without it a stuck task would stall polling
  # for this resource forever, since the next poll is only scheduled once the
  # current one lands.
  @poll_task_timeout_ms 10_000

  # Teardown does one `DELETE` against the provider and must be allowed to
  # finish it: the DynamicSupervisor default of 5s brutal-kills the tracker
  # first, and a resource nobody deleted bills until the Reaper notices.
  @shutdown_timeout_ms 30_000

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
          poll_task: Task.t() | nil,
          poll_timeout: reference() | nil,
          poll_failures: non_neg_integer(),
          upstream_deletable?: boolean(),
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
      restart: :temporary,
      shutdown: @shutdown_timeout_ms,
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
      poll_task: nil,
      poll_timeout: nil,
      poll_failures: 0,
      upstream_deletable?: true,
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

  def handle_info(:status_poll, %{poll_task: nil} = state) do
    case start_poll(state) do
      {:ok, task} ->
        timer = Process.send_after(self(), {:poll_timeout, task.ref}, @poll_task_timeout_ms)
        {:noreply, %{state | poll_task: task, poll_timeout: timer}}

      :error ->
        apply_observation({:poll_failed, :no_task_supervisor}, state)
    end
  end

  # A poll is already in flight. Don't stack a second request on a provider
  # that is evidently struggling, and don't schedule anything either — the
  # in-flight poll schedules its successor when it lands.
  def handle_info(:status_poll, state), do: {:noreply, state}

  def handle_info({:poll_timeout, ref}, %{poll_task: %Task{ref: ref} = task} = state) do
    Task.shutdown(task, :brutal_kill)
    apply_observation({:poll_failed, :timeout}, clear_poll(state))
  end

  def handle_info({ref, observation}, %{poll_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    apply_observation(observation, clear_poll(state))
  end

  # The poll task died — a raise on the poll path, e.g. a key that resolves to
  # nil or a body the translator can't read. We could not tell whether the
  # resource is alive, and uncertainty is never a reason to tear one down.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{poll_task: %Task{ref: ref}} = state) do
    apply_observation({:poll_failed, reason}, clear_poll(state))
  end

  # Late replies from a poll we already gave up on, and anything else. Because
  # this server traps exits, an unmatched message would run `terminate/2` and
  # DELETE a perfectly healthy resource.
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_poll(state)
    Events.broadcast(state.compute.id, {:terminating, reason})

    if state.upstream_deletable? do
      terminate_upstream(state)
    else
      # Nothing left to delete — a DELETE would only earn us an error and a
      # misleading `{:terminate_failed, _}`.
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
    state = %{state | upstream_deletable?: deletable?(upstream)}

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
        release_old(state)
        :ok = Registry.unregister(ComputeRegistry, {:compute, old_id})
        {:ok, _} = Registry.register(ComputeRegistry, {:compute, replacement.id}, nil)

        Events.broadcast(old_id, {:respawned, replacement.id})
        Events.broadcast(replacement.id, {:status, replacement.status})

        state = %{
          state
          | compute: replacement,
            respawns: state.respawns + 1,
            poll_failures: 0,
            upstream_deletable?: true,
            last_activity_ms: now_ms()
        }

        schedule_status_poll(state)
        {:noreply, state}

      {:error, error} ->
        Events.broadcast(old_id, {:respawn_failed, {reason, error}})
        {:stop, :normal, state}
    end
  end

  # A death does not always mean the resource is gone. A reclaimed spot pod
  # reads as `desiredStatus: EXITED` — dead to us, still present upstream,
  # still billable, and invisible to the Reaper, which lists only running
  # resources. The failed-respawn branch already stops (and so terminates it
  # via `terminate/2`); the success branch must delete it explicitly, or a
  # long-running spot session leaks one carcass per preemption.
  defp release_old(%{upstream_deletable?: false}), do: :ok
  defp release_old(state), do: terminate_upstream(state)

  # --- teardown ---

  # Is there anything left for `terminate/2` to delete? Not when the provider
  # has forgotten the id, and not when it is telling us the resource is already
  # terminated: providers that keep terminated records answer the DELETE with
  # an error, which buys nothing, emits a misleading `{:terminate_failed, _}`,
  # and costs the final `{:status, :terminated}` that `Events` documents as the
  # end-of-session signal. Keyed off the observed status rather than the death
  # reason so it also covers `spot: true`, where a terminated resource is
  # reported as `:preempted`.
  defp deletable?(nil), do: false
  defp deletable?(%Spec.Compute{status: :terminated}), do: false
  defp deletable?(%Spec.Compute{}), do: true

  defp terminate_upstream(state) do
    case ExAtlas.terminate(state.compute.id, state.opts) do
      :ok -> Events.broadcast(state.compute.id, {:status, :terminated})
      {:error, err} -> Events.broadcast(state.compute.id, {:terminate_failed, err})
    end
  end

  # --- polling ---

  @doc "Name of the `Task.Supervisor` that runs the status polls."
  @spec task_supervisor_name() :: atom()
  def task_supervisor_name, do: @task_supervisor

  # The poll runs in a supervised, unlinked task so a provider that takes
  # two minutes to answer cannot park this mailbox — `touch/1` and `info/1`
  # keep working, and teardown wins the race for the resource.
  defp start_poll(state) do
    if Process.whereis(@task_supervisor) do
      id = state.compute.id
      opts = poll_opts(state.opts)

      {:ok,
       Task.Supervisor.async_nolink(@task_supervisor, fn -> UpstreamStatus.observe(id, opts) end)}
    else
      :error
    end
  end

  defp poll_opts(opts) do
    Keyword.put(
      opts,
      :req_options,
      Keyword.merge(@poll_req_options, Keyword.get(opts, :req_options, []))
    )
  end

  # Drop the backstop timer with the poll it was guarding, so a landed poll
  # doesn't leave a stray message to be swept up by the catch-all later.
  defp clear_poll(%{poll_timeout: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | poll_task: nil, poll_timeout: nil}
  end

  defp cancel_poll(%{poll_task: nil}), do: :ok
  defp cancel_poll(%{poll_task: task}), do: Task.shutdown(task, :brutal_kill)

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
