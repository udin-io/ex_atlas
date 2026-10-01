defmodule ExAtlas.Providers.RunPod do
  @moduledoc """
  `ExAtlas.Provider` implementation for [RunPod](https://runpod.io).

  Wraps two RunPod APIs through the single ExAtlas contract:

    * **REST management** — pod/endpoint/template/network-volume CRUD and pod
      lifecycle operations, and the GPU catalog. Base URL `https://api.runpod.io/v2`.
    * **Serverless runtime** — job submission, status, streaming against a
      specific endpoint. Base URL `https://api.runpod.ai/v2/<endpoint_id>`.

  All calls go through `Req` (see `ExAtlas.Providers.RunPod.Client`). Authentication
  uses `Authorization: Bearer <api_key>`. Every request emits a `[:ex_atlas, :runpod, :request]` telemetry event.

  ## Capabilities

  RunPod reports the following capability atoms:

      [:serverless, :network_volumes, :http_proxy, :raw_tcp,
       :symmetric_ports, :webhooks, :global_networking, :self_terminate]

  Runpod no longer sells spot pods, so `spot: true` returns
  `{:error, %ExAtlas.Error{kind: :unsupported}}` before any request.

  ## Spawn example

      {:ok, pod} =
        ExAtlas.spawn_compute(
          provider: :runpod,
          gpu: :h100,
          image: "pytorch/pytorch:2.5.0-cuda12.1-cudnn9-runtime",
          cloud_type: :secure,
          ports: [{8000, :http}],
          volume_gb: 50,
          auth: :bearer
        )

      pod.ports
      # [%{internal: 8000, external: nil, protocol: :http,
      #    url: "https://abc123-8000.proxy.runpod.net"}]

  ## Serverless example

      {:ok, job} =
        ExAtlas.run_job(
          provider: :runpod,
          endpoint: "my-endpoint-id",
          input: %{prompt: "hello"},
          mode: :async
        )

      {:ok, done} = ExAtlas.get_job(job.id, provider: :runpod, endpoint: "my-endpoint-id")
  """

  @behaviour ExAtlas.Provider

  alias ExAtlas.Providers.RunPod.{Catalog, Endpoints, Jobs, Pods, Translate}
  alias ExAtlas.Spec

  @impl true
  def capabilities do
    [
      :serverless,
      :network_volumes,
      :http_proxy,
      :raw_tcp,
      :symmetric_ports,
      :webhooks,
      :global_networking,
      :self_terminate
    ]
  end

  @impl true
  def spawn_compute(%Spec.ComputeRequest{spot: true}, _ctx) do
    {:error,
     ExAtlas.Error.new(:unsupported,
       provider: :runpod,
       message: "Runpod no longer offers spot pods; spawn with spot: false"
     )}
  end

  def spawn_compute(%Spec.ComputeRequest{} = req, ctx) do
    {body, auth} = Translate.compute_request_to_pod_create(req)

    with {:ok, pod} <- Pods.create(ctx, body) do
      {:ok, Translate.pod_to_compute(pod, auth)}
    end
  end

  @impl true
  def get_compute(id, ctx) do
    # A 200 whose body isn't a pod object (RunPod has been seen to answer
    # `null` for a pod mid-teardown) must not blow up the caller — status
    # pollers run this in a loop and a raise there kills their process.
    case Pods.get(ctx, id) do
      {:ok, pod} when is_map(pod) ->
        {:ok, Translate.pod_to_compute(pod)}

      {:ok, other} ->
        {:error,
         ExAtlas.Error.new(:provider,
           provider: :runpod,
           message: "unexpected body for GET /pods/#{id}",
           raw: other
         )}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  # REST v2 filters nothing server-side, so every filter applies here, to the
  # translated `Compute`, the same way `ExAtlas.Providers.Mock` applies them.
  def list_compute(filters, ctx) do
    with {:ok, pods} <- Pods.list(ctx) do
      {:ok,
       pods
       |> Enum.map(&Translate.pod_to_compute/1)
       |> Enum.filter(&matches_filters?(&1, filters))}
    end
  end

  @impl true
  def stop(id, ctx) do
    case Pods.stop(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def start(id, ctx) do
    case Pods.start(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def terminate(id, ctx) do
    case Pods.delete(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def run_job(%Spec.JobRequest{endpoint: endpoint, mode: :sync, timeout_ms: timeout} = req, ctx) do
    body = Translate.job_request_to_body(req)

    with {:ok, response} <- Jobs.run_sync(ctx, endpoint, body, timeout) do
      {:ok, Translate.job_response_to_job(response, endpoint)}
    end
  end

  def run_job(%Spec.JobRequest{endpoint: endpoint} = req, ctx) do
    body = Translate.job_request_to_body(req)

    with {:ok, response} <- Jobs.run(ctx, endpoint, body) do
      {:ok, Translate.job_response_to_job(response, endpoint)}
    end
  end

  @impl true
  def get_job(id, %{job_endpoint: endpoint} = ctx) when is_binary(endpoint),
    do: do_get_job(id, endpoint, ctx)

  def get_job(id, ctx) do
    case Map.get(ctx, :endpoint) do
      endpoint when is_binary(endpoint) ->
        do_get_job(id, endpoint, ctx)

      _ ->
        {:error,
         ExAtlas.Error.new(:validation,
           provider: :runpod,
           message:
             "get_job requires :endpoint in ctx (pass `endpoint: \"...\"` to the top-level call)"
         )}
    end
  end

  defp do_get_job(id, endpoint, ctx) do
    with {:ok, response} <- Jobs.status(ctx, endpoint, id) do
      {:ok, Translate.job_response_to_job(response, endpoint)}
    end
  end

  @impl true
  def cancel_job(id, ctx) do
    endpoint = Map.get(ctx, :endpoint) || Map.get(ctx, :job_endpoint)

    if endpoint do
      case Jobs.cancel(ctx, endpoint, id) do
        {:ok, _} -> :ok
        err -> err
      end
    else
      {:error,
       ExAtlas.Error.new(:validation,
         provider: :runpod,
         message: "cancel_job requires :endpoint in ctx"
       )}
    end
  end

  @impl true
  def stream_job(id, ctx) do
    case Map.get(ctx, :endpoint) || Map.get(ctx, :job_endpoint) do
      nil ->
        Stream.map([{:error, ExAtlas.Error.new(:validation, provider: :runpod)}], & &1)

      endpoint ->
        Jobs.stream(ctx, endpoint, id)
    end
  end

  @impl true
  def list_gpu_types(ctx) do
    with {:ok, secure} <- Catalog.list_gpus(ctx, "SECURE"),
         {:ok, community} <- Catalog.list_gpus(ctx, "COMMUNITY") do
      {:ok, Translate.gpu_types(secure, community)}
    end
  end

  @doc false
  def endpoints_module, do: Endpoints

  # --- helpers ---

  defp matches_filters?(compute, filters) do
    Enum.all?(filters, fn
      {:status, s} -> compute.status == s
      {:name, n} -> compute.name == n
      {:region, r} -> compute.region == r
      {:gpu, g} -> gpu_matches?(compute.gpu_type, g)
      _ -> true
    end)
  end

  defp gpu_matches?(gpu_type, canonical) do
    case Spec.GpuCatalog.for_provider(canonical, :runpod) do
      {:ok, id} -> gpu_type == id
      {:error, _} -> false
    end
  end
end
