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

  @network_volume_request_keys [:name, :size_gb, :region, :tier, :provider_opts]

  @doc """
  List the account's network volumes.

  Returns `{:error, %ExAtlas.Error{kind: :unsupported}}` for a provider that
  cannot manage volumes; `:manage_network_volumes` in `capabilities/1` says
  which can.
  """
  @spec list_network_volumes(opts()) :: {:ok, [Spec.NetworkVolume.t()]} | {:error, term()}
  def list_network_volumes(opts \\ []), do: dispatch_optional(:list_network_volumes, [], opts)

  @doc "Fetch a network volume by id."
  @spec get_network_volume(String.t(), opts()) :: {:ok, Spec.NetworkVolume.t()} | {:error, term()}
  def get_network_volume(id, opts \\ []), do: dispatch_optional(:get_network_volume, [id], opts)

  @doc """
  Create a network volume.

  Takes `:name` and `:size_gb` (required), `:region` and `:tier`; see
  `ExAtlas.Spec.NetworkVolumeRequest`. RunPod also needs `:region`. Other
  options are provider config, as in `spawn_compute/1`.

      {:ok, volume} =
        ExAtlas.create_network_volume(
          provider: :runpod, name: "datasets", size_gb: 200, region: "EU-RO-1"
        )

  Mount it with `spawn_compute(network_volume_id: volume.id)`.
  """
  @spec create_network_volume(opts()) :: {:ok, Spec.NetworkVolume.t()} | {:error, term()}
  def create_network_volume(opts) when is_list(opts) do
    {request_opts, config_opts} = Keyword.split(opts, @network_volume_request_keys)
    req = Spec.NetworkVolumeRequest.new!(request_opts)
    dispatch_optional(:create_network_volume, [req], config_opts)
  end

  @doc "Delete a network volume. The provider destroys the data on it."
  @spec delete_network_volume(String.t(), opts()) :: :ok | {:error, term()}
  def delete_network_volume(id, opts \\ []),
    do: dispatch_optional(:delete_network_volume, [id], opts)

  @template_request_keys [
    :name,
    :image,
    :ports,
    :env,
    :container_disk_gb,
    :volume_gb,
    :command,
    :serverless,
    :ssh,
    :jupyter,
    :provider_opts
  ]

  @doc """
  List the account's templates, every page.

  Returns `{:error, %ExAtlas.Error{kind: :unsupported}}` for a provider that
  cannot manage templates; `:manage_templates` in `capabilities/1` says which
  can.
  """
  @spec list_templates(opts()) :: {:ok, [Spec.Template.t()]} | {:error, term()}
  def list_templates(opts \\ []), do: dispatch_optional(:list_templates, [], opts)

  @doc "Fetch a template by id."
  @spec get_template(String.t(), opts()) :: {:ok, Spec.Template.t()} | {:error, term()}
  def get_template(id, opts \\ []), do: dispatch_optional(:get_template, [id], opts)

  @doc """
  Create a template: a saved image, ports, env and disk to spawn pods from.

  Takes `:name` and `:image` (required), plus `:ports`, `:env`,
  `:container_disk_gb`, `:volume_gb`, `:command`, `:serverless`, `:ssh` and
  `:jupyter`; see `ExAtlas.Spec.TemplateRequest`. RunPod turns SSH and Jupyter
  on unless `ssh: false` or `jupyter: false` says otherwise. Other options are
  provider config, as in `spawn_compute/1`.

      {:ok, template} =
        ExAtlas.create_template(
          provider: :runpod,
          name: "trainer-v7",
          image: "ghcr.io/acme/trainer:7",
          ports: [{8000, :http}],
          container_disk_gb: 80
        )

  Spawn from it with `spawn_compute(template_id: template.id)`. A spawn that
  sets no `:ports` or `:container_disk_gb` keeps the template's.
  """
  @spec create_template(opts()) :: {:ok, Spec.Template.t()} | {:error, term()}
  def create_template(opts) when is_list(opts) do
    {request_opts, config_opts} = Keyword.split(opts, @template_request_keys)
    req = Spec.TemplateRequest.new!(request_opts)
    dispatch_optional(:create_template, [req], config_opts)
  end

  @doc "Delete a template. RunPod refuses while a pod or endpoint uses it."
  @spec delete_template(String.t(), opts()) :: :ok | {:error, term()}
  def delete_template(id, opts \\ []), do: dispatch_optional(:delete_template, [id], opts)

  @doc """
  One pod's spend so far, in US dollars, split into GPU, CPU and disk.

  Providers that cannot report spend return
  `{:error, %ExAtlas.Error{kind: :unsupported}}`; `:billing` in
  `capabilities/1` says which can.

  ## Options

    * `:from`, `:to` - `DateTime` bounds of the window. With neither, the
      provider covers its own default window: RunPod's last 30 days. The
      returned `from` and `to` show the window the total covers.
    * every other option is provider config, as in `spawn_compute/1`.

  ## Example

      {:ok, spend} = ExAtlas.compute_spend("pod_9", provider: :runpod)
      spend.total_usd
      # => 12.34

  RunPod's docs do not say how soon a new hour of spend shows up here. Do not
  read the total as a live cost.
  """
  @spec compute_spend(String.t(), opts()) :: {:ok, Spec.Spend.t()} | {:error, term()}
  def compute_spend(id, opts \\ []) when is_binary(id) do
    {window, config_opts} = Keyword.split(opts, [:from, :to])

    case Enum.reject(window, fn {_key, value} -> match?(%DateTime{}, value) end) do
      [] ->
        dispatch_optional(:compute_spend, [id, window], config_opts)

      [{key, _value} | _] ->
        {:error, ExAtlas.Error.new(:validation, message: "#{inspect(key)} must be a DateTime")}
    end
  end

  @doc """
  List the account's serverless endpoints, every page.

  Returns `{:error, %ExAtlas.Error{kind: :unsupported}}` for a provider that
  cannot manage endpoints; `:manage_endpoints` in `capabilities/1` says which
  can. Pass an endpoint's `id` as `endpoint:` to `run_job/1`.

  This library does not create endpoints. Create one in the provider's console.
  """
  @spec list_endpoints(opts()) :: {:ok, [Spec.Endpoint.t()]} | {:error, term()}
  def list_endpoints(opts \\ []), do: dispatch_optional(:list_endpoints, [], opts)

  @doc "Fetch a serverless endpoint by id."
  @spec get_endpoint(String.t(), opts()) :: {:ok, Spec.Endpoint.t()} | {:error, term()}
  def get_endpoint(id, opts \\ []), do: dispatch_optional(:get_endpoint, [id], opts)

  @doc "Delete a serverless endpoint."
  @spec delete_endpoint(String.t(), opts()) :: :ok | {:error, term()}
  def delete_endpoint(id, opts \\ []), do: dispatch_optional(:delete_endpoint, [id], opts)

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

  # For callbacks a provider may leave out (`@optional_callbacks`): a provider
  # without one gets a normalized `:unsupported` error, not an
  # `UndefinedFunctionError`, so Mock, Stub and user modules need no change.
  defp dispatch_optional(fun, args, opts) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    module = Config.provider_module(provider)
    arity = length(args) + 1

    if Code.ensure_loaded?(module) and function_exported?(module, fun, arity) do
      apply(module, fun, args ++ [ctx])
    else
      {:error,
       ExAtlas.Error.new(:unsupported,
         provider: provider,
         message: "#{inspect(module)} does not implement #{fun}/#{arity}"
       )}
    end
  end
end
