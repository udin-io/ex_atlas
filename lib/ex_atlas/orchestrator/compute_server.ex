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

  ## Interactive mode and task mode

  `mode: :interactive` (the default) is the transient-per-user session the rest
  of this moduledoc describes: it lives as long as someone keeps `touch/1`ing
  it and dies of an idle TTL.

  `mode: :task` is the same server rented to run one command to completion —
  see `ExAtlas.Orchestrator.run_task/1`. Three things change:

    * **The heartbeat clock is never started.** Unattended work has no
      heartbeats to miss, and the default 30-minute idle TTL would otherwise
      kill a 90-minute training run. `touch/1` still answers, it just has
      nothing to postpone.
    * **`:max_runtime_ms` arms a one-shot deadline** in `init/1`, measured as
      wall clock from spawn rather than from `:running`. Billing starts when
      the resource is rented, so the cap should measure what the meter
      measures, and an image pull is exactly the unbounded cost worth capping.
      It is never re-armed, so a respawn inherits what is left of the budget
      instead of starting a fresh one — "90 minutes" must not be able to spend
      360 by being preempted three times.
    * **`:ready_timeout_ms` arms a second, shorter one-shot timer** that fails
      the task as `{:failed, :never_ready}` if the resource is still
      `:provisioning` when it fires. An image that will not pull leaves a
      rented pod with no container in it; without this it would burn the whole
      `:max_runtime_ms` budget doing nothing.

  Whether an observation ends a task, and how, is decided by the pure
  `ExAtlas.Orchestrator.TaskOutcome`, so this server keeps two extra timers and
  one extra branch rather than a second personality.

  ## Why a task needs both a self-terminating container and a deadline

  RunPod's REST API reports no container state at all — see
  `ExAtlas.Spec.ComputeRequest`'s `:self_terminate`. A pod whose command has
  exited keeps answering `desiredStatus: "RUNNING"`, so polling can never
  detect a normal finish; only the container deleting itself can, and that
  arrives here as a 404, i.e. `{:dead, :vanished, nil}`.

  The deadline covers the disjoint set the container cannot: a SIGKILL or OOM
  kill that runs no cleanup, a hung process, an image that never pulled, and
  `self_terminate: false`. Neither mechanism alone is sufficient, which is why
  `run_task/1` defaults both on.

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

  alias ExAtlas.Orchestrator.{ComputeRegistry, Events, TaskOutcome, TrackingStore, UpstreamStatus}
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

  # How long to wait, after a container has reported its exit code, for the
  # resource to actually disappear. It normally does within a second — the
  # finish POST is sent from the same trap that then DELETEs the pod — so this
  # is the backstop for the case where the DELETE never happened:
  # `self_terminate: false`, an image with no curl, a provider hiccup. Without
  # it those tasks can only ever end at `:max_runtime_ms`.
  @default_finish_grace_ms 60 * 1_000

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
    mode: [type: {:in, [:interactive, :task]}, default: :interactive],
    max_runtime_ms: [
      type: {:or, [:pos_integer, {:in, [false]}]},
      default: false
    ],
    ready_timeout_ms: [
      type: {:or, [:pos_integer, {:in, [false]}]},
      default: false
    ],
    callback: [type: {:or, [:map, nil]}, default: nil],
    allow_insecure_callback: [type: :boolean, default: false],
    finish_grace_ms: [
      type: {:or, [:pos_integer, {:in, [false]}]},
      default: @default_finish_grace_ms
    ],
    user_id: [type: :any, default: nil],
    persist: [type: :boolean, default: false]
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
          mode: TaskOutcome.mode(),
          deadline_at_ms: integer() | nil,
          callback_task_id: String.t() | nil,
          finish_grace_ms: pos_integer() | nil,
          report: TaskOutcome.report(),
          user_id: term() | nil,
          store: module() | nil
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
    with {:ok, tracking} <- opts |> Keyword.take(@option_keys) |> NimbleOptions.validate(@schema) do
      validate_persist_mode(tracking)
    end
  end

  # `persist: true` is a promise that the resource can be rebuilt at boot, and
  # for an interactive session it cannot: `compute.auth.token` is a bearer
  # credential `ExAtlas.Auth.Token` promises is never written down, so an
  # adopted session would come back with `auth: nil` — a pod nobody can reach,
  # billing for another full idle TTL, for a user whose browser is long gone.
  # Refused here rather than silently ignored, at the same boundary as every
  # other tracking option and for the same reason: before anything is rented.
  defp validate_persist_mode(tracking) do
    if tracking[:persist] and tracking[:mode] != :task do
      {:error,
       %NimbleOptions.ValidationError{
         key: :persist,
         value: true,
         message:
           "invalid value for :persist option: only mode: :task can be persisted and adopted. " <>
             "An interactive session's auth token is never stored, so an adopted one would be " <>
             "unreachable and would bill for another idle TTL."
       }}
    else
      {:ok, tracking}
    end
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
      mode: tracking[:mode],
      deadline_at_ms: deadline_at(tracking[:max_runtime_ms]),
      callback_task_id: callback_task_id(tracking[:callback]),
      finish_grace_ms: finish_grace(tracking[:finish_grace_ms]),
      report: nil,
      user_id: tracking[:user_id],
      store: store_for(tracking[:persist])
    }

    register_callback(state.callback_task_id)
    Events.broadcast(compute.id, {:status, compute.status})
    schedule_heartbeat(state)
    schedule_status_poll(state)
    schedule_deadline(tracking[:max_runtime_ms])
    schedule_ready_timeout(state, tracking[:ready_timeout_ms])
    {:ok, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_activity_ms: now_ms()}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info =
      state
      |> Map.take([:compute, :last_activity_ms, :user_id, :idle_ttl_ms, :mode])
      |> Map.put(:max_runtime_remaining_ms, remaining_ms(state.deadline_at_ms))

    {:reply, info, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    idle_for = now_ms() - state.last_activity_ms

    if idle_for >= state.idle_ttl_ms do
      Events.broadcast(state.compute.id, {:terminating, :idle_timeout})
      {:stop, :normal, state}
    else
      Events.broadcast(state.compute.id, {:heartbeat, now_ms()})
      schedule_heartbeat(state)
      {:noreply, state}
    end
  end

  # The wall-clock backstop. It is the only thing that ends a task whose
  # container died without running its self-termination trap — a SIGKILL, an
  # OOM kill, a wedged process — because RunPod keeps reporting such a pod as
  # RUNNING and billing for it indefinitely.
  def handle_info(:max_runtime, state), do: finish(:timed_out, state)

  # A resource still provisioning this late is not slow, it is stuck: an image
  # that will not pull leaves a rented, billing pod with no container in it.
  # Failing here rather than waiting for `:max_runtime_ms` turns hours of
  # wasted spend into minutes.
  def handle_info(:ready_timeout, %{compute: %{status: :provisioning}} = state),
    do: finish({:failed, :never_ready}, state)

  def handle_info(:ready_timeout, state), do: {:noreply, state}

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

  # --- pod callbacks ---
  #
  # These arrive from `ExAtlas.Callback.ingest/3` as plain messages, never as
  # calls: the web request that carried them must not be able to block on this
  # mailbox, and an untrusted pod must not get a lever on it.

  # Relayed verbatim and retained nowhere. `ExAtlas.Callback` has already
  # checked that the payload is a JSON object; what is *in* it is a convention
  # between the container and its subscribers, not something to reinterpret
  # here.
  #
  # Progress deliberately does not `touch/1`. It would let a compromised pod
  # postpone its own idle TTL indefinitely, and in `:task` mode — the only mode
  # that arms a deadline — there is no idle clock to postpone anyway. The
  # option would carry risk exactly where it carries no benefit.
  def handle_info({:atlas_callback, :progress, payload}, state) do
    Events.broadcast(state.compute.id, {:progress, payload})
    {:noreply, state}
  end

  def handle_info({:atlas_callback, :log, payload}, state) do
    Events.broadcast(state.compute.id, {:log, payload})
    {:noreply, state}
  end

  # First report wins. A replayed or retried `finish` is therefore idempotent
  # — it cannot rewrite the recorded outcome, and it cannot buy the pod another
  # grace window either.
  def handle_info({:atlas_callback, :finish, _payload}, %{report: %{}} = state),
    do: {:noreply, state}

  def handle_info({:atlas_callback, :finish, report}, state) do
    # Recorded *before* the broadcast, so the report is durable the moment a
    # subscriber learns of it. It is what makes "never respawn something that
    # already reported" survive a restart: without it an adopted task that
    # finished during the downtime could be re-run on a meter.
    update_record(state, &%{&1 | report: report})
    Events.broadcast(state.compute.id, {:task_report, report})
    {:noreply, arm_finish_grace(%{state | report: report})}
  end

  # The report landed but the resource never disappeared: the trap was skipped,
  # `self_terminate: false`, or the container's own DELETE failed. Finish on
  # what the container said and let `terminate/2` issue the DELETE, which is
  # what actually stops the meter.
  def handle_info(:finish_grace, %{report: nil} = state), do: {:noreply, state}

  def handle_info(:finish_grace, state),
    do: finish(TaskOutcome.from_report(state.report), state)

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
      forget(state, state.compute.id)
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
      case TaskOutcome.classify({:dead, reason, upstream}, state.mode, state.report) do
        :none -> {:stop, :normal, state}
        outcome -> finish(outcome, state)
      end
    end
  end

  # --- task outcomes ---

  # Announce the outcome *before* stopping, so the `{:task, _}` event precedes
  # the `{:terminating, _}` / `{:status, :terminated}` pair that `Events`
  # documents as the end-of-session signal. A subscriber that ignores task
  # events still sees a correct lifecycle; one that reads them learns why the
  # session ended before it ends.
  defp finish(outcome, state) do
    Events.broadcast(state.compute.id, {:task, outcome})
    {:stop, :normal, state}
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

  # A compute that reported `finish` is never respawned, whatever the provider
  # says happened to it. On spot capacity a disappearance means both
  # "self-terminated fine" and "reclaimed", and without a marker the two are
  # indistinguishable — which is how `on_failure: {:respawn, n}` ends up
  # re-running work that already finished, on a meter.
  defp respawn?(reason, state),
    do:
      is_nil(state.report) and reason in @respawnable and
        state.respawns < state.respawn_limit

  defp respawn(state, reason) do
    old_id = state.compute.id

    case ExAtlas.spawn_compute(state.opts) do
      {:ok, replacement} ->
        # Before `release_old/1`, which deletes the old record along with the
        # old resource. The replacement inherits the original `spawned_at_ms`
        # so an adopted deadline still measures from the *first* spawn — a
        # record that re-anchored here would hand a task preempted three times
        # three times its budget, which is exactly what the in-memory deadline
        # already refuses to do.
        carry_record(state, old_id, replacement.id)
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

  # --- durable tracking ---
  #
  # `ExAtlas.Orchestrator.spawn/1` writes the record; this server owns it from
  # then on. Every write goes through the configured
  # `ExAtlas.Orchestrator.TrackingStore`, which is `nil` unless this spawn
  # asked for `persist: true` — so an opted-out session touches no store at
  # all and behaves exactly as it did before the store existed.

  defp store_for(false), do: nil
  defp store_for(true), do: TrackingStore.impl()

  defp update_record(%{store: nil}, _fun), do: :ok

  defp update_record(%{store: store} = state, fun) do
    case store.get(state.compute.id) do
      {:ok, record} -> store.put(fun.(record))
      :error -> :ok
    end
  end

  defp carry_record(%{store: nil}, _old_id, _new_id), do: :ok

  defp carry_record(%{store: store} = state, old_id, new_id) do
    case store.get(old_id) do
      {:ok, record} ->
        store.put(%{record | id: new_id, respawns: state.respawns + 1})
        store.delete(old_id)

      :error ->
        :ok
    end
  end

  defp forget(%{store: nil}, _id), do: :ok
  defp forget(%{store: store}, id), do: store.delete(id)

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
      :ok ->
        Events.broadcast(state.compute.id, {:status, :terminated})
        forget(state, state.compute.id)

      {:error, err} ->
        # The record deliberately stays: we asked the provider to delete this
        # and it refused, so the resource may well still be running and
        # billing. Leaving the record means the next boot re-adopts it and
        # tries again, instead of the Reaper being the only thing left that
        # could reclaim it.
        Events.broadcast(state.compute.id, {:terminate_failed, err})
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

  # Unattended work has no heartbeats to miss. Scheduling the idle clock in
  # task mode would let the default 30-minute TTL kill a 90-minute training
  # run, so in task mode it is never started at all — `touch/1` still accepts
  # calls, it simply has nothing to postpone.
  defp schedule_heartbeat(%{mode: :task}), do: :ok

  defp schedule_heartbeat(%{heartbeat_ms: ms}), do: Process.send_after(self(), :heartbeat, ms)

  # One-shot, armed here and never re-armed: a respawn inherits what is left of
  # the original budget rather than starting a fresh one. `:max_runtime_ms` is
  # a wall-clock spend cap, and a caller who asked for 90 minutes must not be
  # able to spend 360 by being preempted three times.
  defp schedule_deadline(false), do: :ok
  defp schedule_deadline(ms), do: Process.send_after(self(), :max_runtime, ms)

  # Readiness is a claim about *observed* status, so there is nothing to check
  # without the status poller — with it disabled the deadline is the only
  # backstop.
  defp schedule_ready_timeout(_state, false), do: :ok
  defp schedule_ready_timeout(%{status_poll_ms: nil}, _ms), do: :ok
  defp schedule_ready_timeout(_state, ms), do: Process.send_after(self(), :ready_timeout, ms)

  # One-shot, and armed only by the first report — see the `finish` clause of
  # `handle_info/2`. Interactive sessions have no task to end, so a report
  # there is announced and nothing more.
  defp arm_finish_grace(%{mode: :task, finish_grace_ms: ms} = state) when is_integer(ms) do
    Process.send_after(self(), :finish_grace, ms)
    state
  end

  defp arm_finish_grace(state), do: state

  defp schedule_status_poll(%{status_poll_ms: nil}), do: :ok

  defp schedule_status_poll(%{status_poll_ms: base, poll_failures: failures}) do
    Process.send_after(self(), :status_poll, UpstreamStatus.next_interval_ms(base, failures))
  end

  # --- opts ---

  defp poll_interval(false), do: nil
  defp poll_interval(ms) when is_integer(ms) and ms > 0, do: ms

  defp respawn_limit(:stop), do: 0
  defp respawn_limit({:respawn, max}), do: max

  defp deadline_at(false), do: nil
  defp deadline_at(ms), do: now_ms() + ms

  defp finish_grace(false), do: nil
  defp finish_grace(ms) when is_integer(ms) and ms > 0, do: ms

  defp callback_task_id(nil), do: nil
  defp callback_task_id(%{task_id: task_id}), do: task_id

  # Registered alongside the `{:compute, id}` key this server is named by, and
  # *not* re-keyed on a respawn: the task id is what the credential in the
  # pod's environment is bound to, and it has to keep working when the compute
  # id underneath it is replaced.
  defp register_callback(nil), do: :ok

  defp register_callback(task_id) do
    {:ok, _} = Registry.register(ComputeRegistry, {:callback, task_id}, nil)
    :ok
  end

  defp remaining_ms(nil), do: nil
  defp remaining_ms(at), do: max(at - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
