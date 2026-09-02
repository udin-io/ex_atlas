defmodule ExAtlas.Orchestrator do
  @moduledoc """
  Opt-in OTP orchestration for transient-per-user compute sessions.

  The core `ExAtlas` API is stateless — each call hits the provider directly. The
  orchestrator adds one lightweight `GenServer` per spawned resource. That server:

    * Holds the resource's metadata (id, auth handle, proxy URL, user context).
    * Heartbeats the resource via `touch/1` so idle sessions auto-terminate.
    * Traps exits and calls `ExAtlas.terminate/2` on shutdown, guaranteeing no
      leaked pods.
    * Broadcasts state changes over `Phoenix.PubSub` so LiveViews can react.

  The full supervision tree (`Registry` + `DynamicSupervisor` + `PubSub` + `Reaper`)
  only starts when you opt in:

      # config/config.exs
      config :ex_atlas, start_orchestrator: true

  When opted out (the default), ExAtlas boots with no processes — library-only
  consumers never pay for processes they don't use.

  ## Spawning a tracked resource

      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :runpod,
          gpu: :h100,
          image: "pytorch/pytorch:2.5.0-cuda12.1-cudnn9-runtime",
          ports: [{8000, :http}],
          auth: :bearer,
          user_id: current_user.id,
          idle_ttl_ms: 15 * 60_000
        )

      # LiveView can subscribe for state changes:
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

  ## Heartbeating

      # Any time the user is still actively using the session:
      ExAtlas.Orchestrator.touch(compute.id)

  Missing a heartbeat for `idle_ttl_ms` triggers graceful termination.

  ## Manual termination

      :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)
  """

  alias ExAtlas.Callback

  alias ExAtlas.Orchestrator.{
    ComputeRegistry,
    ComputeServer,
    ComputeSupervisor,
    Events,
    TrackingStore
  }

  alias ExAtlas.Spec

  @pubsub ExAtlas.PubSub

  # A task with no wall-clock cap is the billing trap this whole feature exists
  # to close, so `run_task/1` supplies one rather than letting a caller create
  # an unbounded meter by omission. Both are overridable per call.
  @default_task_max_runtime_ms 60 * 60 * 1_000

  # Doubles as the default for `await_ready/2`: both answer "how long may this
  # thing take to become usable before we stop believing it will".
  @default_ready_timeout_ms 15 * 60 * 1_000

  # The statuses `ExAtlas.Orchestrator.Events` documents as ends rather than
  # steps. They are `UpstreamStatus`'s death reasons plus the `:terminated`
  # that closes a teardown, and a wait can never be satisfied after one.
  @dead_statuses [:failed, :stopped, :terminated, :vanished, :preempted]

  @doc """
  Spawn a compute resource under supervision.

  Returns `{:ok, pid, compute}` where `pid` is the tracking `GenServer` and
  `compute` is the `ExAtlas.Spec.Compute` normally returned by `ExAtlas.spawn_compute/1`.

  The tracking options (`:idle_ttl_ms`, `:heartbeat_ms`, `:status_poll_ms`,
  `:on_failure`, `:mode`, `:max_runtime_ms`, `:ready_timeout_ms`,
  `:finish_grace_ms`, `:callback`, `:user_id`, `:persist`)
  are validated *before* the provider is called, so
  a typo costs nothing: an unvalidated option that only blew up in the
  tracker's `init/1` would leave the resource running — and billing — with
  nothing tracking it.

  ## `persist: true` — surviving a deploy

  Off by default. When set (and only for `mode: :task`), the resource is
  recorded in the configured `ExAtlas.Orchestrator.TrackingStore` before its
  tracker starts, so the next boot can re-adopt it instead of letting the
  Reaper reclaim it as an orphan. See `ExAtlas.Orchestrator.TrackingStore` for
  what is stored, and `ExAtlas.Orchestrator.Adopter` for what happens at boot.
  """
  @spec spawn(keyword()) ::
          {:ok, pid(), ExAtlas.Spec.Compute.t()}
          | {:error, term()}
  def spawn(opts) do
    ensure_running!()

    with {:ok, opts} <- Callback.prepare(opts),
         {:ok, tracking} <- ComputeServer.validate_opts(opts),
         {:ok, compute} <- ExAtlas.spawn_compute(opts) do
      persist(compute, opts, tracking)
      track(compute, opts, tracking)
    end
  end

  # Written *after* the provider hands back an id and *before* the tracker
  # starts, so the only window in which a live resource is unrecorded is the
  # provider call itself — the same window `:reap_grace_ms` already covers.
  # See `ExAtlas.Orchestrator.TrackingStore` for what is stored and what is
  # deliberately not.
  defp persist(compute, opts, tracking) do
    with true <- Keyword.get(tracking, :persist, false),
         store when not is_nil(store) <- TrackingStore.impl() do
      store.put(TrackingStore.new(compute, opts, tracking))
    end
  end

  defp track(compute, opts, tracking) do
    case DynamicSupervisor.start_child(ComputeSupervisor, {ComputeServer, {compute, opts}}) do
      {:ok, pid} ->
        {:ok, pid, compute}

      {:ok, pid, _info} ->
        {:ok, pid, compute}

      {:error, reason} ->
        # The resource exists upstream but nothing will ever track it, so it
        # would bill until the Reaper noticed. Take it down with the tracker —
        # and with the record, or the next boot would adopt a pod we just
        # deleted.
        _ = ExAtlas.terminate(compute.id, opts)
        forget(compute.id, tracking)
        {:error, {:tracker_start_failed, reason}}
    end
  end

  defp forget(id, tracking) do
    with true <- Keyword.get(tracking, :persist, false),
         store when not is_nil(store) <- TrackingStore.impl() do
      store.delete(id)
    end
  end

  @doc """
  Run a container to completion, then destroy it and report what happened.

  A thin wrapper over `spawn/1` with `mode: :task`, for the batch shape:
  "run this image with this command until it exits, then tell me the outcome
  and stop the meter."

      {:ok, pid, compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :runpod,
          gpu: :rtx_4090,
          image: "ghcr.io/acme/trainer:latest",
          command: ["/app/train.sh"],
          name: "atlas-task-\#{run.id}",
          max_runtime_ms: :timer.minutes(90)
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

  Subscribers get one of three task events before the usual
  `{:terminating, _}` / `{:status, :terminated}` pair:

    * `{:task, :completed}`
    * `{:task, :timed_out}`
    * `{:task, {:failed, reason}}` — `:never_ready`, `:preempted`,
      `:terminated`, `:failed`, or `{:exit_code, n}`

  ## Reporting back: the `:callback` option

  Pass `callback: "https://your-app.example.com/atlas/cb"` (or configure
  `config :ex_atlas, :callback, base_url: ...`) and ExAtlas mints a task-scoped
  credential, injects `ATLAS_CALLBACK_URL` / `ATLAS_CALLBACK_TOKEN` /
  `ATLAS_TASK_ID` into the container, and has the self-termination trap POST
  the exit code before the pod goes. Mount `ExAtlas.Callback.Plug` to receive
  it. See the "Pod callbacks" guide.

  With a callback, `{:task, :completed}` is **proven** and a non-zero exit
  arrives as `{:task, {:failed, {:exit_code, n}}}`. Subscribers also get
  `{:progress, payload}`, `{:log, payload}` and `{:task_report, report}`.

  Related options: `:finish_grace_ms` (default 60s) is how long to wait, after
  a report lands, for the resource to actually disappear before finishing on
  the report anyway; `:allow_insecure_callback` lets a loopback or plain-HTTP
  URL through for local development.

  ## Surviving a deploy: `persist: true`

  A multi-hour task and a routine deploy do not mix by default. The registry
  is in memory, so a restart leaves the pod running with nothing tracking it —
  and `ExAtlas.Orchestrator.Reaper` reclaims exactly that. Pass
  `persist: true` to record the task durably and have
  `ExAtlas.Orchestrator.Adopter` rebuild its tracker at the next boot, on
  what is *left* of `:max_runtime_ms` rather than a fresh budget. See
  `ExAtlas.Orchestrator.TrackingStore`.

  ## Without a callback, `:completed` does not mean "succeeded"

  It means **the container ended and the resource is gone**. The
  self-termination wrapper traps `EXIT`, so a crashed command cleans up exactly
  like a successful one and both reach the orchestrator as the same 404; the
  exit code dies with the pod, and RunPod's REST API offers no way to read it
  back. That is precisely the ambiguity `:callback` removes — and it is a
  strictly additive feature, so omitting it costs nothing that was ever there.

  ## Two mechanisms, both required

  RunPod reports no container state at all, so a pod whose command has exited
  keeps answering `desiredStatus: "RUNNING"` and keeps billing. Self-termination
  (`:self_terminate`, on by default whenever `:command` is set) is the only
  thing that produces a normal-exit signal. `:max_runtime_ms` is the only cover
  for the cases where nothing in the container can run: a SIGKILL or OOM kill,
  a hung process, an image that never pulled, `self_terminate: false`. Neither
  alone is sufficient, so both are on by default.

  ## Defaults this adds on top of `spawn/1`

    * `mode: :task` — always, it is what the function means.
    * `max_runtime_ms:` 60 minutes, if you did not say. There is no way to
      disable it here: an unattended task with no cap is the trap.
    * `ready_timeout_ms:` 15 minutes, if you did not say. Applies only while
      the resource is still `:provisioning`, and only when the status poller
      is running.
    * `finish_grace_ms:` 60 seconds. Only ever armed by a callback report, so
      it does nothing at all without `:callback`.

  Note that `:max_runtime_ms` is wall clock **from spawn**, not compute time
  and not time since `:running` — image-pull time counts against it, because
  it counts against your bill. It also carries across an `on_failure:
  {:respawn, n}` replacement rather than resetting, so a preempted task cannot
  spend a multiple of the budget you asked for.

  ## Spot tasks

  With `spot: true` a disappearing resource is reported as `:preempted`
  (`ExAtlas.Orchestrator.UpstreamStatus` infers preemption; no provider signals
  it). A self-terminating container also makes the resource disappear, so on
  spot capacity the two are **indistinguishable from the API**: a task that
  finished can be read as preempted and, with `on_failure: {:respawn, n}`,
  re-run. Use respawn for spot tasks only where re-running is harmless —
  checkpoint-resuming training, which is what the option was added for — and
  note the carried deadline bounds the total spend either way.

  A `:callback` removes that ambiguity: a task that reported `finish` is never
  respawned, and a preemption observed after a clean report is read as
  `:completed`.
  """
  @spec run_task(keyword()) ::
          {:ok, pid(), ExAtlas.Spec.Compute.t()} | {:error, term()}
  def run_task(opts) do
    opts
    |> Keyword.put(:mode, :task)
    |> Keyword.put_new(:max_runtime_ms, @default_task_max_runtime_ms)
    |> Keyword.put_new(:ready_timeout_ms, @default_ready_timeout_ms)
    |> __MODULE__.spawn()
  end

  @doc """
  Block until a tracked resource is `:running`, dies, or the timeout expires.

      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(provider: :runpod, gpu: :h100, ...)

      case ExAtlas.Orchestrator.await_ready(compute.id, timeout_ms: 120_000) do
        {:ok, ready}                    -> ready.ports
        {:error, {:dead, reason, _}}    -> {:error, reason}
        {:error, {:timeout, last_seen}} -> maybe_give_it_longer(last_seen)
      end

  Same result shape as `ExAtlas.await_ready/2` — see `t:ExAtlas.await_result/0`.

  ## It adds no requests to your provider

  A tracked resource is already being polled by its
  `ExAtlas.Orchestrator.ComputeServer`, which broadcasts `{:status, :running}`
  the moment upstream says so. This subscribes to that stream rather than
  opening a second poll, so awaiting ten pods costs the provider nothing beyond
  the ten polls already running. It reads the tracker's current state *after*
  subscribing, so a resource that came up in between is not missed — and one
  that is already up returns without waiting at all.

  The corollary: the wait is only as timely as `:status_poll_ms`, and with
  `status_poll_ms: false` nothing observes upstream, so the wait can report
  only what the tracker already knew. Pass an untracked id — or call
  `ExAtlas.await_ready/2` with the provider opts — if you want your own poll.

  An id that is not tracked falls back to `ExAtlas.await_ready/2`, so this is
  safe to call for both; that path needs the usual `:provider` / `:api_key`
  opts, and honours `:poll_interval_ms`.

  ## Across a respawn

  With `on_failure: {:respawn, n}` a preempted resource is replaced rather than
  ended, and the session the caller is waiting on continues under a new id. The
  wait follows it and resolves on the replacement, on the *original* deadline —
  a caller who allowed two minutes must not be able to spend six by being
  preempted twice.

  ## It runs in the calling process

  Which means it subscribes on your behalf and consumes `{:atlas_compute, id,
  _}` messages for that id while it waits. Call it from a process that is not
  itself subscribed to the resource's topic — a `Task`, `start_async/3`, a job
  worker — rather than from the LiveView that is also listening.
  """
  @spec await_ready(String.t(), keyword()) :: ExAtlas.await_result()
  def await_ready(id, opts \\ []) when is_binary(id) do
    ensure_running!()
    {timeout_ms, opts} = Keyword.pop(opts, :timeout_ms, @default_ready_timeout_ms)

    with {:ok, pid} <- lookup(id),
         true <- pubsub_running?() do
      await_tracked(id, pid, timeout_ms)
    else
      _untracked_or_unannounced ->
        ExAtlas.await_ready(id, Keyword.put(opts, :timeout_ms, timeout_ms))
    end
  end

  # `ExAtlas.Orchestrator.Events` silently skips broadcasts when the host app
  # has no `phoenix_pubsub`. With nothing announcing anything there is no event
  # stream to wait on, so the wait polls the provider itself rather than
  # sitting out its timeout in silence.
  defp pubsub_running?,
    do: Code.ensure_loaded?(Phoenix.PubSub) and is_pid(Process.whereis(@pubsub))

  defp await_tracked(id, pid, timeout_ms) do
    ref = Process.monitor(pid)
    subscribe(id)

    # Read only after subscribing: a resource that becomes ready between the
    # two is announced on a topic we are already on, so neither ordering can
    # lose the transition.
    {result, last_id} = await_from(id, ref, monotonic_ms() + timeout_ms, nil, nil)

    unsubscribe(last_id)
    Process.demonitor(ref, [:flush])
    result
  end

  # Resolve against what the tracker holds right now, and keep waiting if that
  # is not readiness. Every entry into the wait goes through here — including
  # the `{:status, :running}` announcement itself, because the tracker is the
  # authority on the resource and the event is only a nudge to go and ask it.
  defp await_from(id, ref, deadline, last, death) do
    case tracked_compute(id) do
      %Spec.Compute{status: :running} = compute -> {{:ok, compute}, id}
      nil -> {settle(death || :terminated, last), id}
      compute -> await_event(id, ref, deadline, compute, death)
    end
  end

  # Returns the id it finished on as well as the result, because a respawn
  # moves the wait to a different topic and the subscription taken out on the
  # caller's behalf has to be cleaned up wherever it ended.
  #
  # `death` is the cause the tracker has announced but not yet acted on — see
  # the dead-status clause.
  defp await_event(id, ref, deadline, last, death) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {settle(death, last), id}
    else
      receive do
        {:atlas_compute, ^id, {:status, :running}} ->
          await_from(id, ref, deadline, last, death)

        # A cause, not yet an ending: with `on_failure: {:respawn, n}` the
        # tracker announces *why* the resource died and only then decides
        # whether to replace it, so resolving here would report a session that
        # is about to continue as over. The first cause wins, and the tracker
        # going away is what makes it final.
        {:atlas_compute, ^id, {:status, status}} when status in @dead_statuses ->
          await_event(id, ref, deadline, last, death || status)

        {:atlas_compute, ^id, {:respawned, new_id}} ->
          follow_respawn(id, new_id, ref, deadline, last)

        # Everything else on this topic is a step — including `{:poll_failed,
        # _}`, which says the provider could not be reached, not that the
        # resource will never come up. Consumed rather than left behind so the
        # wait does not fill the caller's mailbox with its own subscription.
        {:atlas_compute, ^id, _event} ->
          await_event(id, ref, deadline, last, death)

        # Nothing will ever announce readiness now. If a cause was broadcast
        # first this is what confirms it; otherwise the session ended without
        # one — an idle timeout, a `stop_tracked/1`, a crash.
        {:DOWN, ^ref, :process, _pid, _reason} ->
          {settle(death || :terminated, last), id}
      after
        remaining -> {settle(death, last), id}
      end
    end
  end

  defp settle(nil, last), do: {:error, {:timeout, last}}
  defp settle(reason, last), do: {:error, {:dead, reason, last}}

  # The cause is dropped, not carried: the resource it described has been
  # replaced, and the replacement gets to fail on its own terms.
  defp follow_respawn(old_id, new_id, ref, deadline, last) do
    unsubscribe(old_id)
    subscribe(new_id)
    await_from(new_id, ref, deadline, last, nil)
  end

  # A `GenServer.call` to a tracker that is already shutting down exits in the
  # *caller*. This wait runs in the caller's process, and a resource being torn
  # down is something to report, never something to inherit.
  defp tracked_compute(id) do
    case info(id) do
      {:ok, %{compute: compute}} -> compute
      {:error, :not_tracked} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp subscribe(id), do: Phoenix.PubSub.subscribe(@pubsub, Events.topic(id))
  defp unsubscribe(id), do: Phoenix.PubSub.unsubscribe(@pubsub, Events.topic(id))

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc "Record activity so the idle-reaper keeps the resource alive."
  @spec touch(String.t()) :: :ok | {:error, :not_tracked}
  def touch(id) do
    case lookup(id) do
      {:ok, pid} -> ComputeServer.touch(pid)
      :error -> {:error, :not_tracked}
    end
  end

  @doc """
  Fetch the latest tracked state for a resource.

  The map holds `:compute`, `:user_id`, `:idle_ttl_ms`, `:last_activity_ms`,
  `:mode`, and `:max_runtime_remaining_ms` — milliseconds left on a task's
  `:max_runtime_ms` deadline, or `nil` when there is no deadline.
  """
  @spec info(String.t()) :: {:ok, map()} | {:error, :not_tracked}
  def info(id) do
    case lookup(id) do
      {:ok, pid} -> {:ok, ComputeServer.info(pid)}
      :error -> {:error, :not_tracked}
    end
  end

  @doc "Gracefully stop tracking and terminate the upstream resource."
  @spec stop_tracked(String.t()) :: :ok | {:error, :not_tracked}
  def stop_tracked(id) do
    case lookup(id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(ComputeSupervisor, pid)
        :ok

      :error ->
        {:error, :not_tracked}
    end
  end

  @doc "Return the list of currently-tracked resource ids."
  @spec list_ids() :: [String.t()]
  def list_ids do
    ensure_running!()

    Registry.select(ComputeRegistry, [{{{:compute, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @doc false
  def lookup(id) do
    case Registry.lookup(ComputeRegistry, {:compute, id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp ensure_running! do
    unless Application.get_env(:ex_atlas, :start_orchestrator, false) do
      raise "ExAtlas.Orchestrator is not started. Set `config :ex_atlas, start_orchestrator: true` " <>
              "and ensure :ex_atlas is in your extra_applications."
    end
  end
end
