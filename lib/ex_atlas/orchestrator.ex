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
  alias ExAtlas.Orchestrator.{ComputeRegistry, ComputeServer, ComputeSupervisor}

  # A task with no wall-clock cap is the billing trap this whole feature exists
  # to close, so `run_task/1` supplies one rather than letting a caller create
  # an unbounded meter by omission. Both are overridable per call.
  @default_task_max_runtime_ms 60 * 60 * 1_000
  @default_task_ready_timeout_ms 15 * 60 * 1_000

  @doc """
  Spawn a compute resource under supervision.

  Returns `{:ok, pid, compute}` where `pid` is the tracking `GenServer` and
  `compute` is the `ExAtlas.Spec.Compute` normally returned by `ExAtlas.spawn_compute/1`.

  The tracking options (`:idle_ttl_ms`, `:heartbeat_ms`, `:status_poll_ms`,
  `:on_failure`, `:mode`, `:max_runtime_ms`, `:ready_timeout_ms`,
  `:finish_grace_ms`, `:callback`, `:user_id`)
  are validated *before* the provider is called, so
  a typo costs nothing: an unvalidated option that only blew up in the
  tracker's `init/1` would leave the resource running — and billing — with
  nothing tracking it.
  """
  @spec spawn(keyword()) ::
          {:ok, pid(), ExAtlas.Spec.Compute.t()}
          | {:error, term()}
  def spawn(opts) do
    ensure_running!()

    with {:ok, opts} <- Callback.prepare(opts),
         {:ok, _tracking} <- ComputeServer.validate_opts(opts),
         {:ok, compute} <- ExAtlas.spawn_compute(opts) do
      track(compute, opts)
    end
  end

  defp track(compute, opts) do
    case DynamicSupervisor.start_child(ComputeSupervisor, {ComputeServer, {compute, opts}}) do
      {:ok, pid} ->
        {:ok, pid, compute}

      {:ok, pid, _info} ->
        {:ok, pid, compute}

      {:error, reason} ->
        # The resource exists upstream but nothing will ever track it, so it
        # would bill until the Reaper noticed. Take it down with the tracker.
        _ = ExAtlas.terminate(compute.id, opts)
        {:error, {:tracker_start_failed, reason}}
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
    |> Keyword.put_new(:ready_timeout_ms, @default_task_ready_timeout_ms)
    |> __MODULE__.spawn()
  end

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
