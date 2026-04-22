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

  alias ExAtlas.{Config, Spec}

  @type opts :: keyword()

  @doc """
  Spawn a compute resource.

  Accepts either a keyword list (convenience) or a pre-built
  `ExAtlas.Spec.ComputeRequest`. See `ExAtlas.Spec.ComputeRequest` for the full
  field list.
  """
  @spec spawn_compute(opts()) :: {:ok, Spec.Compute.t()} | {:error, term()}
  def spawn_compute(opts) when is_list(opts) do
    {provider, opts} = Config.pop_provider!(opts)
    {request_opts, config_opts} = split_request_opts(opts)
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
    {request_opts, config_opts} = split_request_opts(opts)
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

  @request_keys [
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
    :provider_opts,
    # JobRequest keys
    :endpoint,
    :input,
    :mode,
    :timeout_ms,
    :webhook,
    :policy
  ]

  defp split_request_opts(opts), do: Keyword.split(opts, @request_keys)

  defp dispatch(fun, args, opts) do
    {provider, opts} = Config.pop_provider!(opts)
    ctx = Config.build_ctx(provider, opts)
    provider |> Config.provider_module() |> apply(fun, args ++ [ctx])
  end
end
