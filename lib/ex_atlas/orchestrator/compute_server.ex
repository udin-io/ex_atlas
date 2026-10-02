defmodule ExAtlas.Orchestrator.ComputeServer do
  @moduledoc """
  One `GenServer` per tracked compute resource.

  Responsibilities:

    * Hold the resource's normalized `ExAtlas.Spec.Compute`, its `:user_id`,
      `:idle_ttl_ms`, last-activity timestamp, and spawn opts.
    * Trap exits so `terminate/2` calls `ExAtlas.terminate/2` on the
      upstream provider — even on supervisor shutdown or crash. The one
      exception is a `persist: true` task on a node stop: see "Adopted
      trackers".
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

  ## The cost cap

  With `max_cost: dollars` the server keeps an `ExAtlas.Orchestrator.CostMeter`
  from `init/1`: the resource's `cost_per_hour` times the time it has run,
  summed over segments. A status poll that reports a new price, and a respawn,
  each start a segment. The server arms one timer for the moment spend reaches
  the cap at the current rate, rather than checking on the heartbeat, which
  never runs in task mode. When it fires, an interactive session broadcasts
  `{:terminating, :cost_cap}` and a task broadcasts `{:task, {:failed,
  :cost_cap}}` first; both stop, and `terminate/2` deletes the resource. A cost
  cap is never respawned, and a respawn carries the spend, as it carries the
  `:max_runtime_ms` deadline.

  Every `:reconcile_spend_ms` a capped server reads the current pod's bill,
  in a task like the status poll. A bill above the pod's estimate raises the
  spend (`ExAtlas.Orchestrator.CostMeter.reconcile/3`), rewrites the tracking
  record and re-arms the timer; a lower bill changes nothing, since billing
  lags. An `:unsupported` answer stops the reads for the session, silently.
  A bill asked for before a respawn is ignored: it is for the old pod.

  ## Adopted trackers

  With `persist: true` a task is recorded in an
  `ExAtlas.Orchestrator.TrackingStore`, and after a restart
  `ExAtlas.Orchestrator.Adopter` starts this server with `{:adopted, record}`
  instead of `{compute, opts}`. The difference is entirely about budgets that
  must not refill: `deadline_at_ms` is monotonic and meaningless in a new VM,
  so the deadline is recomputed from the record's **wall-clock**
  `:spawned_at_ms` — a 90-minute task that was down for two hours fires
  `:max_runtime` at once rather than starting a second 90 minutes — and the
  `on_failure` budget and any landed report are carried across as well. A
  `max_cost` meter resumes from the record's spend and counts the downtime at
  the record's last known price, since the pod billed while the node was
  down; the tracker rewrites those fields at every new price. The
  first status poll runs immediately, since nothing has watched the resource
  since the node went down.

  A graceful node stop leaves such a task's resource running and its record
  in place: its supervisor's `:shutdown` is the one reason `terminate/2` does
  not delete for. A task whose container already reported its exit code still
  deletes, as does one whose record is missing from the store (no boot could
  adopt it) and `ExAtlas.Orchestrator.stop_tracked/1`, whose reason is
  `{:shutdown, :stopped}`.

  ## Why a task needs both a self-terminating container and a deadline

  Runpod's REST API reports no exit code — see
  `ExAtlas.Spec.ComputeRequest`'s `:self_terminate`. A pod whose command has
  exited keeps answering `status: "RUNNING"`, so polling can never
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

  alias ExAtlas.Orchestrator.{
    ComputeRegistry,
    CostMeter,
    Events,
    TaskOutcome,
    Timer,
    TrackingStore,
    UpstreamStatus
  }

  alias ExAtlas.Spec

  @task_supervisor ExAtlas.Orchestrator.TaskSupervisor

  @default_idle_ttl_ms 30 * 60 * 1_000
  @default_heartbeat_interval_ms 60 * 1_000

  # RunPod's management API publishes no rate limits at all, so the default is
  # deliberately unhurried: one request per resource per minute is cheap for
  # the provider and still bounds wasted spend to roughly a minute, which is
  # the same window the Reaper already works on.
  @default_status_poll_ms 60 * 1_000

  # One billing request per capped pod every 15 minutes. RunPod's billing lags
  # by an amount its docs do not state, so checking more often buys little.
  @default_reconcile_spend_ms 15 * 60 * 1_000

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
  #
  # Every option that arms a timer is bounded by `Timer.option_type/0`.
  @schema [
    idle_ttl_ms: [type: :pos_integer, default: @default_idle_ttl_ms],
    heartbeat_ms: [type: Timer.option_type(), default: @default_heartbeat_interval_ms],
    status_poll_ms: [
      type: {:or, [Timer.option_type(), {:in, [false]}]},
      default: @default_status_poll_ms
    ],
    on_failure: [
      type: {:or, [{:in, [:stop]}, {:tuple, [{:in, [:respawn]}, :non_neg_integer]}]},
      default: :stop
    ],
    mode: [type: {:in, [:interactive, :task]}, default: :interactive],
    max_runtime_ms: [
      type: {:or, [Timer.option_type(), {:in, [false]}]},
      default: false
    ],
    ready_timeout_ms: [
      type: {:or, [Timer.option_type(), {:in, [false]}]},
      default: false
    ],
    callback: [type: {:or, [:map, nil]}, default: nil],
    allow_insecure_callback: [type: :boolean, default: false],
    finish_grace_ms: [
      type: {:or, [Timer.option_type(), {:in, [false]}]},
      default: @default_finish_grace_ms
    ],
    user_id: [type: :any, default: nil],
    persist: [type: :boolean, default: false],
    max_cost: [
      type: {:or, [{:custom, __MODULE__, :validate_max_cost, []}, {:in, [false]}]},
      default: false
    ],
    reconcile_spend_ms: [
      type: {:or, [Timer.option_type(), {:in, [false]}]},
      default: @default_reconcile_spend_ms
    ]
  ]

  @option_keys Keyword.keys(@schema)

  @timer_option_keys [
    :heartbeat_ms,
    :status_poll_ms,
    :max_runtime_ms,
    :ready_timeout_ms,
    :finish_grace_ms,
    :reconcile_spend_ms
  ]

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
          store: module() | nil,
          cost_meter: CostMeter.t() | nil,
          cost_timer: {reference(), reference()} | nil,
          reconcile_spend_ms: pos_integer() | nil,
          reconcile_task: {Task.t(), String.t()} | nil,
          reconcile_timeout: reference() | nil,
          spend_from: DateTime.t()
        }

  @doc false
  def start_link(arg) do
    arg = sealed(arg)
    name = {:via, Registry, {ComputeRegistry, {:compute, tracked_id(arg)}}}
    GenServer.start_link(__MODULE__, arg, name: name)
  end

  def child_spec(arg) do
    %{
      id: {:compute_server, tracked_id(arg)},
      start: {__MODULE__, :start_link, [arg]},
      restart: :temporary,
      shutdown: @shutdown_timeout_ms,
      type: :worker
    }
  end

  # `Orchestrator.spawn/1` has sealed these already; a tracker started
  # directly gets the same, so its state never holds a raw key. A record holds
  # no credential, but one written before env values were left out holds them.
  defp sealed({:adopted, %{opts: opts} = record}) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} -> {:adopted, %{record | opts: Keyword.put(opts, :env, seal_stored_env(env))}}
      :error -> {:adopted, record}
    end
  end

  defp sealed({compute, opts}) do
    case ExAtlas.Config.seal_credentials(opts) do
      {:ok, opts} -> {compute, opts}
      {:error, error} -> raise error
    end
  end

  defp seal_stored_env(env) when is_map(env),
    do: Map.new(env, fn {name, value} -> {name, seal_stored_value(value)} end)

  defp seal_stored_env(env), do: env

  defp seal_stored_value(:not_stored), do: :not_stored
  defp seal_stored_value(value), do: ExAtlas.Secret.wrap(value)

  defp tracked_id({:adopted, record}), do: record.id
  defp tracked_id({compute, _opts}), do: compute.id

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

  @doc false
  def validate_max_cost(dollars) when is_number(dollars) and dollars > 0, do: {:ok, dollars}

  def validate_max_cost(other),
    do: {:error, "expected a positive number of US dollars, got: #{inspect(other)}"}

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

  @doc """
  Stop the tracker and delete its resource, persisted or not.

  The reason is `{:shutdown, :stopped}`, never the supervisor's `:shutdown`,
  so `terminate/2` can tell an explicit stop from a node stop. Returns `:ok`
  when the tracker has already exited, and after 30 s while it is still
  deleting.
  """
  def stop(pid) do
    GenServer.stop(pid, {:shutdown, :stopped}, @shutdown_timeout_ms)
  catch
    :exit, _ -> :ok
  end

  # --- callbacks ---

  @impl true
  # Re-adoption at boot — see `ExAtlas.Orchestrator.Adopter`. The record is
  # what survived the VM; `:compute` is the observation the Adopter just made
  # and is never persisted.
  #
  # Three things differ from a fresh spawn, and each of them is a budget that
  # must not refill:
  #
  #   * The deadline is recomputed from the record's wall-clock
  #     `:spawned_at_ms`, not re-armed from `:max_runtime_ms`. A task that
  #     spent its whole budget while the node was down fires `:max_runtime` at
  #     once rather than starting a second one.
  #   * `:respawns` and `:report` are carried, so an `on_failure: {:respawn, n}`
  #     budget stays spent and work that already reported is never re-run.
  #   * The cost meter resumes from the record's spend, and counts the downtime
  #     at the record's last known rate: the pod billed while the node was
  #     down. A budget spent by then fires `:cost_cap` at once.
  #   * `:ready_timeout_ms` is deliberately *not* re-armed. It answers "did
  #     this ever come up?", and an adopted resource has been up for hours.
  def init({:adopted, record}) do
    Process.flag(:trap_exit, true)

    %{compute: compute} = record
    opts = adopted_staging(record.opts)

    tracking =
      opts |> Keyword.take(@option_keys) |> bound_timers() |> NimbleOptions.validate!(@schema)

    remaining_ms = record |> remaining_runtime_ms() |> bound_timer()

    state =
      %{
        new_state(compute, opts, tracking)
        | respawns: record.respawns,
          report: record.report,
          deadline_at_ms: deadline_at(remaining_ms),
          store: TrackingStore.impl(),
          cost_meter: resumed_cost_meter(record),
          spend_from: DateTime.from_unix!(record.spawned_at_ms, :millisecond)
      }
      |> reprice()
      |> arm_cost_cap()

    register_callback(state.callback_task_id)
    Events.broadcast(compute.id, {:status, compute.status})
    schedule_heartbeat(state)
    schedule_deadline(remaining_ms)
    schedule_reconcile(state)
    # Nothing has watched this resource since the node went down, so the first
    # look is now rather than one poll interval from now.
    poll_now(state)
    {:ok, state}
  end

  def init({compute, opts}) do
    Process.flag(:trap_exit, true)

    # Already validated by `ExAtlas.Orchestrator.spawn/1`; re-run so a directly
    # started tracker gets the same defaults and the same clear failure.
    tracking = NimbleOptions.validate!(Keyword.take(opts, @option_keys), @schema)
    state = compute |> new_state(opts, tracking) |> arm_cost_cap()

    register_callback(state.callback_task_id)
    Events.broadcast(compute.id, {:status, compute.status})
    schedule_heartbeat(state)
    schedule_status_poll(state)
    schedule_deadline(tracking[:max_runtime_ms])
    schedule_ready_timeout(state, tracking[:ready_timeout_ms])
    schedule_reconcile(state)
    {:ok, state}
  end

  defp new_state(compute, opts, tracking) do
    %{
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
      store: store_for(tracking[:persist]),
      cost_meter: cost_meter(tracking[:max_cost], compute),
      cost_timer: nil,
      reconcile_spend_ms: poll_interval(tracking[:reconcile_spend_ms]),
      reconcile_task: nil,
      reconcile_timeout: nil,
      spend_from: spend_from(compute)
    }
  end

  # A record never holds `s3:` credentials, so its `s3:` is marked as such
  # even when a host store dropped the marker: without it a respawn would rent
  # a replacement with the URIs and no keys.
  defp adopted_staging(opts) do
    case Keyword.get(opts, :s3) do
      nil ->
        opts

      s3 when is_map(s3) and not is_struct(s3) ->
        Keyword.put(opts, :s3, Map.put(s3, :credentials, :not_stored))

      other ->
        Keyword.put(opts, :s3, Spec.Staging.scrub(other))
    end
  end

  # What is left of a wall-clock budget, measured from the spawn that started
  # it. `0` means the budget is gone and the deadline fires on the next pass
  # through the mailbox.
  defp remaining_runtime_ms(%{max_runtime_ms: false}), do: false

  defp remaining_runtime_ms(%{max_runtime_ms: ms, spawned_at_ms: spawned_at_ms}),
    do: max(ms - (System.system_time(:millisecond) - spawned_at_ms), 0)

  # The record's open segment began at wall-clock `cost_since_ms`; the meter
  # runs on monotonic time, so the segment start moves back by the segment's
  # age, run time and downtime alike. A wall clock behind the one that wrote
  # the record clamps that age at 0: the open segment counts nothing rather
  # than a refund. `reprice/1` then opens a segment at the adopted compute's
  # rate.
  #
  # A host store without the cost columns hands back `nil` or no key at all.
  # Its record adopts with a fresh budget (or none, without a cap) rather than
  # crashing `init/1`, which would leave the pod with no tracker and no
  # deadline.
  defp resumed_cost_meter(%{max_cost: max_cost} = record)
       when is_number(max_cost) and max_cost > 0 do
    now_wall = System.system_time(:millisecond)
    since_wall = number_or(Map.get(record, :cost_since_ms), now_wall)
    spent = number_or(Map.get(record, :spent_usd), 0.0)
    age_ms = max(now_wall - since_wall, 0)

    CostMeter.resume(max_cost, spent, Map.get(record, :cost_rate), now_ms() - age_ms)
  end

  defp resumed_cost_meter(_uncapped), do: nil

  # A record written before timer options were bounded can hold a longer
  # delay. Refusing it would leave the pod running with no tracker, so it is
  # adopted at the bound: a 60-day deadline fires after about 49.7 days.
  defp bound_timers(tracking) do
    Enum.map(tracking, fn
      {key, ms} when key in @timer_option_keys -> {key, bound_timer(ms)}
      other -> other
    end)
  end

  defp bound_timer(ms) when is_integer(ms), do: min(ms, Timer.max_ms())
  defp bound_timer(other), do: other

  defp number_or(value, _default) when is_number(value), do: value
  defp number_or(_missing, default), do: default

  defp poll_now(%{status_poll_ms: nil}), do: :ok
  defp poll_now(_state), do: send(self(), :status_poll)

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
      |> Map.merge(cost_info(state.cost_meter))

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

  # Only the timer armed last carries the ref in state. One cancelled after it
  # fired arrives with an older ref and falls to the catch-all.
  def handle_info({:cost_cap, ref}, %{cost_timer: {_timer, ref}} = state) do
    state = %{state | cost_timer: nil}

    if CostMeter.capped?(state.cost_meter, now_ms()) do
      stop_on_cost_cap(state)
    else
      # Float rounding left the spend a hair under the cap.
      {:noreply, arm_cost_cap(state)}
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

  # --- billing reconciliation ---
  #
  # Run like the status poll: in a task, so a slow billing API never parks
  # this mailbox. The task remembers the pod it asked about.

  def handle_info(
        :reconcile_spend,
        %{reconcile_task: nil, reconcile_spend_ms: ms, cost_meter: %CostMeter{}} = state
      )
      when is_integer(ms) do
    case start_reconcile(state) do
      {:ok, task} ->
        timer = Process.send_after(self(), {:reconcile_timeout, task.ref}, @poll_task_timeout_ms)
        {:noreply, %{state | reconcile_task: {task, state.compute.id}, reconcile_timeout: timer}}

      :error ->
        reconcile_failed(:no_task_supervisor, state)
    end
  end

  def handle_info(:reconcile_spend, state), do: {:noreply, state}

  def handle_info(
        {:reconcile_timeout, ref},
        %{reconcile_task: {%Task{ref: ref} = task, _pod_id}} = state
      ) do
    Task.shutdown(task, :brutal_kill)
    reconcile_failed(:timeout, clear_reconcile(state))
  end

  def handle_info({ref, result}, %{reconcile_task: {%Task{ref: ref}, pod_id}} = state) do
    Process.demonitor(ref, [:flush])
    apply_bill(result, pod_id, clear_reconcile(state))
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{reconcile_task: {%Task{ref: ref}, _pod_id}} = state
      ) do
    reconcile_failed(reason, clear_reconcile(state))
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

  # OTP prints the whole state in a crash report. Print it without the provider
  # credential in `opts` or the resource's bearer token, which `compute.auth`
  # holds and `compute.raw` can echo back in the container's env.
  @impl true
  def format_status(%{state: %{opts: opts, compute: compute} = state} = status) do
    compute = %{compute | auth: compute.auth && :redacted, raw: :redacted}
    %{status | state: %{state | opts: TrackingStore.scrub_opts(opts), compute: compute}}
  end

  def format_status(status), do: status

  @impl true
  def terminate(reason, state) do
    cancel_poll(state)
    cancel_reconcile(state)
    Events.broadcast(state.compute.id, {:terminating, reason})

    cond do
      # A node stop (SIGTERM, `System.stop/0`, `Application.stop(:ex_atlas)`)
      # reaches every tracker as its supervisor's `:shutdown`. A persisted task
      # with no report yet keeps its pod and its record, so the next boot
      # adopts it. The node cannot tell a deploy from a machine removed for
      # good; both keep the pod. Without a record no boot can adopt it, so it
      # is deleted.
      reason == :shutdown and is_nil(state.report) and recorded?(state) ->
        :ok

      state.upstream_deletable? ->
        terminate_upstream(state)

      true ->
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

  # The task outcome first, like `finish/2`, then the cause on `:terminating`
  # the way `:idle_timeout` announces itself.
  defp stop_on_cost_cap(state) do
    if state.mode == :task,
      do: Events.broadcast(state.compute.id, {:task, {:failed, :cost_cap}})

    Events.broadcast(state.compute.id, {:terminating, :cost_cap})
    {:stop, :normal, state}
  end

  # --- billing reconciliation ---

  # A bill asked for before a respawn is for a pod this session no longer runs.
  # Its spend is already in the meter.
  defp apply_bill(_result, pod_id, %{compute: %{id: current}} = state) when pod_id != current do
    schedule_reconcile(state)
    {:noreply, state}
  end

  # Spend becomes the larger of the estimate and the bill for the current pod.
  # A lower bill changes nothing: billing lags, so it may only be late.
  defp apply_bill({:ok, %Spec.Spend{total_usd: total}}, _pod_id, state) do
    case CostMeter.usd(total) do
      nil ->
        reconcile_failed(
          ExAtlas.Error.new(:provider,
            provider: state.compute.provider,
            message: "the bill carried no total in US dollars"
          ),
          state
        )

      billed ->
        apply_billed(billed, state)
    end
  end

  # A provider with no billing API answers the same way every time. Stop asking,
  # and say nothing: a failure event every interval, forever, is noise.
  defp apply_bill({:error, %ExAtlas.Error{kind: :unsupported}}, _pod_id, state),
    do: {:noreply, %{state | reconcile_spend_ms: nil}}

  defp apply_bill({:error, error}, _pod_id, state), do: reconcile_failed(error, state)

  defp apply_bill(other, _pod_id, state), do: reconcile_failed({:unexpected, other}, state)

  defp apply_billed(billed, state) do
    now = now_ms()
    meter = state.cost_meter
    estimated = CostMeter.pod_spent_usd(meter, now)

    state =
      case CostMeter.reconcile(meter, billed, now) do
        ^meter ->
          state

        raised ->
          state = %{state | cost_meter: raised}
          record_cost(state)
          arm_cost_cap(state)
      end

    Events.broadcast(
      state.compute.id,
      {:spend_reconciled,
       %{
         estimated_usd: estimated,
         billed_usd: billed,
         spent_usd: CostMeter.spent_usd(state.cost_meter, now)
       }}
    )

    schedule_reconcile(state)
    {:noreply, state}
  end

  defp reconcile_failed(error, state) do
    Events.broadcast(state.compute.id, {:spend_reconcile_failed, error})
    schedule_reconcile(state)
    {:noreply, state}
  end

  # `get_compute/2` can't return the auth handle — it was minted locally at
  # spawn and never left this node — so carry it across every refresh.
  defp refresh_compute(state, upstream) do
    upstream = %{upstream | auth: state.compute.auth}

    if upstream.status != state.compute.status do
      Events.broadcast(state.compute.id, {:status, upstream.status})
    end

    reprice(%{state | compute: upstream})
  end

  # A new price closes the meter's segment, records it, and re-arms the cap
  # timer. A price the meter cannot read, or the same price, changes nothing.
  defp reprice(%{cost_meter: nil} = state), do: state

  defp reprice(%{cost_meter: meter} = state) do
    case CostMeter.rate_changed(meter, state.compute.cost_per_hour, now_ms()) do
      ^meter ->
        state

      repriced ->
        state = %{state | cost_meter: repriced}
        record_cost(state)
        arm_cost_cap(state)
    end
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

    case spawn_replacement(state.opts) do
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

        # The meter carries over, like the deadline: a replacement continues
        # the old budget at its own price. Repriced before the broadcast, so
        # the replacement's record holds that price once subscribers hear. Its
        # bill starts at zero, so the meter marks where its spend begins.
        state =
          reprice(%{
            state
            | compute: replacement,
              cost_meter: new_pod(state.cost_meter),
              respawns: state.respawns + 1,
              poll_failures: 0,
              upstream_deletable?: true,
              last_activity_ms: now_ms()
          })

        Events.broadcast(old_id, {:respawned, replacement.id})
        Events.broadcast(replacement.id, {:status, replacement.status})

        schedule_status_poll(state)
        {:noreply, state}

      {:error, error} ->
        Events.broadcast(old_id, {:respawn_failed, {reason, error}})
        {:stop, :normal, state}
    end
  end

  # An adopted task's `s3:` and `env:` came from its record, which never holds
  # the credentials, presigned URLs or env values. A replacement without them
  # would run blind, and `ExAtlas.spawn_compute/1` raises on the markers, so the
  # respawn ends here, before the provider is asked for anything.
  defp spawn_replacement(opts) do
    cond do
      Spec.Staging.not_stored?(Keyword.get(opts, :s3)) ->
        not_stored(opts, "the :s3 staging credentials are")

      names = unstored_env(Keyword.get(opts, :env)) ->
        not_stored(opts, "the :env values#{names} are")

      true ->
        ExAtlas.spawn_compute(opts)
    end
  end

  defp not_stored(opts, what) do
    {:error,
     ExAtlas.Error.new(:validation,
       provider: Keyword.get(opts, :provider),
       message:
         "cannot respawn: #{what} not stored in a tracking record, so a task " <>
           "adopted after a restart has none to give a replacement"
     )}
  end

  # The names of the values a record left out, as a message suffix; `nil` when
  # the env is whole. `TrackingStore.scrub_opts/1` writes both markers.
  defp unstored_env(:not_stored), do: ""

  defp unstored_env(env) when is_map(env) do
    case for {name, :not_stored} <- env, do: name do
      [] -> nil
      names -> " (#{names |> Enum.sort() |> Enum.join(", ")})"
    end
  end

  defp unstored_env(_env), do: nil

  # A death does not always mean the resource is gone. A reclaimed spot pod
  # reads as `status: EXITED` — dead to us, still present upstream,
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
      {:ok, record} -> store.put(record |> fun.() |> TrackingStore.scrub_env())
      :error -> :ok
    end
  end

  # The meter's open segment began at monotonic `since_ms`; the record keeps
  # it as wall clock, which a new VM can still read.
  defp record_cost(%{cost_meter: meter} = state) do
    since_ms = System.system_time(:millisecond) - (now_ms() - meter.since_ms)
    update_record(state, &Map.merge(&1, TrackingStore.cost_fields(meter, since_ms)))
  end

  defp carry_record(%{store: nil}, _old_id, _new_id), do: :ok

  defp carry_record(%{store: store} = state, old_id, new_id) do
    case store.get(old_id) do
      {:ok, record} ->
        store.put(TrackingStore.scrub_env(%{record | id: new_id, respawns: state.respawns + 1}))
        store.delete(old_id)

      :error ->
        :ok
    end
  end

  defp recorded?(%{store: nil}), do: false
  defp recorded?(%{store: store, compute: compute}), do: match?({:ok, _}, store.get(compute.id))

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
       Task.Supervisor.async_nolink(
         @task_supervisor,
         contained(fn -> UpstreamStatus.observe(id, opts) end)
       )}
    else
      :error
    end
  end

  defp start_reconcile(state) do
    if Process.whereis(@task_supervisor) do
      id = state.compute.id
      opts = Keyword.put(poll_opts(state.opts), :from, state.spend_from)

      {:ok,
       Task.Supervisor.async_nolink(
         @task_supervisor,
         contained(fn -> ExAtlas.compute_spend(id, opts) end)
       )}
    else
      :error
    end
  end

  # A raise inside a provider can come after the HTTP client revealed the key,
  # and the BEAM keeps the crashed frame's arguments in the stacktrace. That
  # stacktrace would reach the task's crash log and, as the DOWN reason, the
  # `{:poll_failed, _}` or `{:spend_reconcile_failed, _}` broadcast. Exit
  # instead with the exception's module and the stacktrace with arities only;
  # the exception struct goes too, as its fields can hold the value.
  defp contained(fun) do
    fn ->
      try do
        fun.()
      rescue
        exception -> exit({:crashed, exception.__struct__, arities(__STACKTRACE__)})
      end
    end
  end

  defp arities(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      frame -> frame
    end)
  end

  defp clear_reconcile(%{reconcile_timeout: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    %{state | reconcile_task: nil, reconcile_timeout: nil}
  end

  defp cancel_reconcile(%{reconcile_task: nil}), do: :ok
  defp cancel_reconcile(%{reconcile_task: {task, _pod_id}}), do: Task.shutdown(task, :brutal_kill)

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

  # The bill raises the meter's spend, so there is nothing to reconcile without
  # a meter. An adopted record decides that, not its opts: a store without the
  # cost columns adopts a capped task uncapped.
  defp schedule_reconcile(%{cost_meter: nil}), do: :ok
  defp schedule_reconcile(%{reconcile_spend_ms: nil}), do: :ok

  defp schedule_reconcile(%{reconcile_spend_ms: ms}),
    do: Process.send_after(self(), :reconcile_spend, ms)

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

  # The bill is asked for from the pod's spawn. The provider's own timestamp
  # when it has one, else now: the tracker starts seconds after the spawn, and
  # RunPod snaps the start down to its bucket edge (a day by default).
  defp spend_from(%Spec.Compute{created_at: %DateTime{} = created_at}) do
    now = DateTime.utc_now()
    if DateTime.compare(created_at, now) == :gt, do: now, else: created_at
  end

  defp spend_from(_compute), do: DateTime.utc_now()

  defp new_pod(nil), do: nil
  defp new_pod(meter), do: CostMeter.new_pod(meter, now_ms())

  defp cost_meter(false, _compute), do: nil
  defp cost_meter(max_cost, compute), do: CostMeter.new(max_cost, compute.cost_per_hour, now_ms())

  defp cost_info(nil), do: %{max_cost: false, spent_usd: 0.0}

  defp cost_info(meter),
    do: %{max_cost: meter.max_cost, spent_usd: CostMeter.spent_usd(meter, now_ms())}

  # One timer, for the moment spend reaches the cap at the current rate. A
  # rate change re-arms it; at rate 0.0 there is nothing to wait for.
  defp arm_cost_cap(%{cost_meter: nil} = state), do: state

  defp arm_cost_cap(state) do
    cancel_cost_timer(state.cost_timer)

    case CostMeter.ms_to_cap(state.cost_meter, now_ms()) do
      :infinity ->
        %{state | cost_timer: nil}

      ms ->
        ref = make_ref()
        %{state | cost_timer: {Process.send_after(self(), {:cost_cap, ref}, ms), ref}}
    end
  end

  defp cancel_cost_timer(nil), do: :ok
  defp cancel_cost_timer({timer, _ref}), do: Process.cancel_timer(timer)

  defp remaining_ms(nil), do: nil
  defp remaining_ms(at), do: max(at - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
