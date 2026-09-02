defmodule ExAtlas do
  @moduledoc """
  ExAtlas is a composable, pluggable Elixir SDK for managing GPU and CPU compute
  across multiple cloud providers (RunPod, Fly.io Machines, Lambda Labs, Vast.ai,
  or any module you write that implements `ExAtlas.Provider`).

  The top-level API is intentionally thin: it validates input, resolves the
  provider, builds a ctx, and delegates to the provider module. That means you
  write the same call against RunPod today, Lambda Labs tomorrow, and your own
  bare-metal backend the day after — only the `:provider` option changes.

  ## Quick start

      # 1. Configure
      config :ex_atlas, default_provider: :runpod
      config :ex_atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")

      # 2. Spawn a GPU pod
      {:ok, compute} =
        ExAtlas.spawn_compute(
          gpu: :h100,
          image: "pytorch/pytorch:2.5.0-cuda12.1-cudnn9-runtime",
          ports: [{8000, :http}],
          auth: :bearer
        )

      compute.ports
      # [%{internal: 8000, external: nil, protocol: :http,
      #    url: "https://<pod_id>-8000.proxy.runpod.net"}]

      compute.auth.header
      # "Authorization: Bearer kX9fP..."

      # 3. Your user's browser talks to the pod directly (bearer token guards access).

      # 4. Shut it down when done
      :ok = ExAtlas.terminate(compute.id)

  ## Running a serverless inference job

      {:ok, job} =
        ExAtlas.run_job(
          endpoint: "abc123",
          input: %{prompt: "a beautiful sunset"},
          mode: :async
        )

      {:ok, done} = ExAtlas.get_job(job.id)
      done.output

  ## Stream a job

      ExAtlas.stream_job(job.id) |> Enum.each(&IO.inspect/1)

  ## Swapping providers

      ExAtlas.spawn_compute(provider: :runpod, gpu: :h100, ...)
      ExAtlas.spawn_compute(provider: :lambda_labs, gpu: :h100, ...)  # v0.2
      ExAtlas.spawn_compute(provider: MyInternalCloud.Provider, gpu: :h100, ...)

  See `ExAtlas.Provider` for the behaviour contract and `ExAtlas.Config` for how
  provider + API key resolution works.
  """

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.{Config, Spec}

  # Long enough for an image that is genuinely still pulling, short enough that
  # a caller who forgot to pass one is not blocked for the length of a training
  # run. It is the same budget `ExAtlas.Orchestrator.run_task/1` gives
  # `:ready_timeout_ms`, and for the same reason.
  @default_await_timeout_ms 15 * 60 * 1_000

  # A readiness wait is foreground — someone is looking at "starting…" — so it
  # polls an order of magnitude faster than the tracker's background health
  # check (`:status_poll_ms`, 60s).
  @default_await_poll_interval_ms 5_000

  @type opts :: keyword()

  @typedoc """
  What a readiness wait can end with.

  `{:timeout, compute}` carries the last compute the wait actually observed
  (`nil` if no poll ever succeeded) so the caller can decide whether to keep
  waiting or terminate; `{:dead, reason, compute}` reuses
  `ExAtlas.Orchestrator.UpstreamStatus`'s vocabulary, and its `compute` is
  `nil` when the provider no longer knows the id.
  """
  @type await_result ::
          {:ok, Spec.Compute.t()}
          | {:error, {:timeout, Spec.Compute.t() | nil}}
          | {:error, {:dead, UpstreamStatus.dead_reason(), Spec.Compute.t() | nil}}

  @doc """
  Spawn a compute resource.

  Accepts either a keyword list (convenience) or a pre-built
  `ExAtlas.Spec.ComputeRequest`. See `ExAtlas.Spec.ComputeRequest` for the full
  field list.
  """
  @spec spawn_compute(opts()) :: {:ok, Spec.Compute.t()} | {:error, term()}
  def spawn_compute(opts) when is_list(opts) do
    {provider, opts} = Config.pop_provider!(opts)
    {request_opts, config_opts} = split_compute_request_opts(opts)
    req = Spec.ComputeRequest.new!(request_opts)
    ctx = Config.build_ctx(provider, config_opts)
    provider |> Config.provider_module() |> apply(:spawn_compute, [req, ctx])
  end

  @spec spawn_compute(Spec.ComputeRequest.t(), opts()) ::
          {:ok, Spec.Compute.t()} | {:error, term()}
  def spawn_compute(%Spec.ComputeRequest{} = req, opts) when is_list(opts) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(:spawn_compute, [req, ctx])
  end

  @doc "Fetch a compute resource by id."
  @spec get_compute(String.t(), opts()) :: {:ok, Spec.Compute.t()} | {:error, term()}
  def get_compute(id, opts \\ []), do: dispatch(:get_compute, [id], opts)

  @doc """
  Block until `id` is `:running`, dies, or the timeout expires.

  `spawn_compute/1` returns the moment the provider accepts the rental, which
  is minutes before the container is usable. This is the wait every caller was
  otherwise writing by hand.

      case ExAtlas.await_ready(compute.id, provider: :runpod, timeout_ms: 120_000) do
        {:ok, ready}                    -> ready.ports
        {:error, {:dead, reason, _}}    -> {:error, reason}
        {:error, {:timeout, last_seen}} -> maybe_give_it_longer(last_seen)
      end

  ## Options

    * `:timeout_ms` — total wall clock to wait. Defaults to 15 minutes, and is
      always bounded: there is no way to wait forever.
    * `:poll_interval_ms` — base interval between polls, default 5s. Jittered,
      and backed off exponentially while the provider is failing, by the same
      `ExAtlas.Orchestrator.UpstreamStatus.next_interval_ms/3` the tracker uses.

  Everything else is passed to `get_compute/2`, so `:provider`, `:api_key`,
  `:spot` and friends work exactly as they do there.

  ## Ready means observed `:running`

  Not "running *and* its ports are populated". A port-less resource — every
  `ExAtlas.Orchestrator.run_task/1` pod — would never satisfy that, and on
  RunPod the proxy URLs are derived from the pod id and are present from the
  first response anyway.

  ## A failed poll is not a failure to become ready

  A 5xx, a rate limit or a socket error means *we could not tell*. Those back
  the next poll off and the wait continues to its timeout; only an answer that
  says the resource is failed, stopped, terminated or gone ends it early.
  That is the same rule `ExAtlas.Orchestrator.ComputeServer` polls under, and
  it is why a provider hiccup cannot report a healthy GPU as broken.

  A provider that *raises* is not caught here — the caller's process takes it,
  the way it would from a bare `get_compute/2`. The tracker rescues that case
  only because its poll runs in a task it supervises.

  ## Timing out terminates nothing

  The resource is left exactly as it was, with the last observed `Compute`
  handed back, because "this is taking too long" and "stop paying for this"
  are the caller's decision and not the same decision.

  For a resource tracked by the orchestrator, prefer
  `ExAtlas.Orchestrator.await_ready/2`: it listens to the tracker's existing
  status poll instead of opening a second one.
  """
  @spec await_ready(String.t(), opts()) :: await_result()
  def await_ready(id, opts \\ []) when is_binary(id) do
    {timeout_ms, opts} = Keyword.pop(opts, :timeout_ms, @default_await_timeout_ms)
    {interval_ms, opts} = Keyword.pop(opts, :poll_interval_ms, @default_await_poll_interval_ms)

    poll_until_ready(id, opts, monotonic_ms() + timeout_ms, interval_ms, 0, nil)
  end

  defp poll_until_ready(id, opts, deadline, interval_ms, failures, last) do
    case UpstreamStatus.observe(id, opts) do
      {:alive, %Spec.Compute{status: :running} = compute} ->
        {:ok, compute}

      {:alive, compute} ->
        retry(id, opts, deadline, interval_ms, 0, compute)

      {:dead, reason, compute} ->
        {:error, {:dead, reason, compute}}

      {:poll_failed, _error} ->
        retry(id, opts, deadline, interval_ms, failures + 1, last)
    end
  end

  defp retry(id, opts, deadline, interval_ms, failures, last) do
    remaining = deadline - monotonic_ms()

    if remaining <= 0 do
      {:error, {:timeout, last}}
    else
      # Never overshoot the deadline by a whole poll interval: a caller who
      # asked for 30s must not be held for 65 because the interval was 60.
      wait = min(UpstreamStatus.next_interval_ms(interval_ms, failures), remaining)

      receive do
      after
        wait -> poll_until_ready(id, opts, deadline, interval_ms, failures, last)
      end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc "List compute resources, optionally filtered."
  @spec list_compute(opts()) :: {:ok, [Spec.Compute.t()]} | {:error, term()}
  def list_compute(opts \\ []) do
    {provider, opts} = Config.pop_provider!(opts)
    {filters, config_opts} = Keyword.split(opts, [:status, :name, :region, :gpu])
    ctx = Config.build_ctx(provider, config_opts)
    provider |> Config.provider_module() |> apply(:list_compute, [filters, ctx])
  end

  @doc "Stop a compute resource without destroying storage."
  @spec stop(String.t(), opts()) :: :ok | {:error, term()}
  def stop(id, opts \\ []), do: dispatch(:stop, [id], opts)

  @doc "Resume a stopped compute resource."
  @spec start(String.t(), opts()) :: :ok | {:error, term()}
  def start(id, opts \\ []), do: dispatch(:start, [id], opts)

  @doc "Terminate and destroy a compute resource."
  @spec terminate(String.t(), opts()) :: :ok | {:error, term()}
  def terminate(id, opts \\ []), do: dispatch(:terminate, [id], opts)

  @doc "Submit a serverless inference job."
  @spec run_job(opts()) :: {:ok, Spec.Job.t()} | {:error, term()}
  def run_job(opts) when is_list(opts) do
    {provider, opts} = Config.pop_provider!(opts)
    {request_opts, config_opts} = split_job_request_opts(opts)
    req = Spec.JobRequest.new!(request_opts)
    ctx = Config.build_ctx(provider, config_opts)
    provider |> Config.provider_module() |> apply(:run_job, [req, ctx])
  end

  @spec run_job(Spec.JobRequest.t(), opts()) :: {:ok, Spec.Job.t()} | {:error, term()}
  def run_job(%Spec.JobRequest{} = req, opts) when is_list(opts) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(:run_job, [req, ctx])
  end

  @doc "Fetch a serverless job by id."
  @spec get_job(String.t(), opts()) :: {:ok, Spec.Job.t()} | {:error, term()}
  def get_job(id, opts \\ []), do: dispatch(:get_job, [id], opts)

  @doc "Cancel an in-flight serverless job."
  @spec cancel_job(String.t(), opts()) :: :ok | {:error, term()}
  def cancel_job(id, opts \\ []), do: dispatch(:cancel_job, [id], opts)

  @doc "Stream partial results from a running job as a lazy `Enumerable`."
  @spec stream_job(String.t(), opts()) :: Enumerable.t()
  def stream_job(id, opts \\ []) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(:stream_job, [id, ctx])
  end

  @doc "Return the provider's catalog of GPU types + pricing."
  @spec list_gpu_types(opts()) :: {:ok, [Spec.GpuType.t()]} | {:error, term()}
  def list_gpu_types(opts \\ []) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(:list_gpu_types, [ctx])
  end

  @doc "Return the capability atoms honored by a provider."
  @spec capabilities(atom() | module()) :: [atom()]
  def capabilities(provider), do: provider |> Config.provider_module() |> apply(:capabilities, [])

  # --- helpers ---

  # Each request struct gets its own key list. A single shared list meant
  # `spawn_compute/1` handed `JobRequest`-only keys to `ComputeRequest.new!/1`
  # (and vice versa), which raised on an option that was merely addressed to
  # the other request — `:mode` being the one that matters, since the
  # orchestrator now uses it for `run_task/1`. Anything not listed here is a
  # provider-config option and reaches the ctx untouched.
  @compute_request_keys [
    :gpu,
    :gpu_count,
    :image,
    :cloud_type,
    :spot,
    :region_hints,
    :ports,
    :env,
    :volume_gb,
    :container_disk_gb,
    :network_volume_id,
    :name,
    :template_id,
    :auth,
    :idle_ttl_ms,
    :command,
    :self_terminate,
    :callback,
    :provider_opts
  ]

  @job_request_keys [
    :endpoint,
    :input,
    :mode,
    :timeout_ms,
    :webhook,
    :policy,
    :provider_opts
  ]

  defp split_compute_request_opts(opts), do: Keyword.split(opts, @compute_request_keys)
  defp split_job_request_opts(opts), do: Keyword.split(opts, @job_request_keys)

  defp dispatch(fun, args, opts) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(fun, args ++ [ctx])
  end
end
