defmodule Atlas.Providers.RunPod do
  @moduledoc """
  `Atlas.Provider` implementation for [RunPod](https://runpod.io).

  Wraps three RunPod APIs through the single Atlas contract:

    * **REST management** — pod/endpoint/template/network-volume CRUD and pod
      lifecycle operations. Base URL `https://rest.runpod.io/v1`.
    * **Serverless runtime** — job submission, status, streaming against a
      specific endpoint. Base URL `https://api.runpod.ai/v2/<endpoint_id>`.
    * **Legacy GraphQL** — the only surface that exposes GPU catalog pricing.
      Base URL `https://api.runpod.io/graphql`.

  All calls go through `Req` (see `Atlas.Providers.RunPod.Client`). Authentication
  uses `Authorization: Bearer <api_key>` for REST/runtime and `?api_key=` for
  GraphQL. Every request emits a `[:atlas, :runpod, :request]` telemetry event.

  ## Capabilities

  RunPod reports the following capability atoms:

      [:spot, :serverless, :network_volumes, :http_proxy, :raw_tcp,
       :symmetric_ports, :webhooks, :global_networking]

  ## Spawn example

      {:ok, pod} =
        Atlas.spawn_compute(
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
        Atlas.run_job(
          provider: :runpod,
          endpoint: "my-endpoint-id",
          input: %{prompt: "hello"},
          mode: :async
        )

      {:ok, done} = Atlas.get_job(job.id, provider: :runpod, endpoint: "my-endpoint-id")
  """

  @behaviour Atlas.Provider

  alias Atlas.Providers.RunPod.{Endpoints, GraphQL, Jobs, Pods, Translate}
  alias Atlas.Spec

  @impl true
  def capabilities do
    [
      :spot,
      :serverless,
      :network_volumes,
      :http_proxy,
      :raw_tcp,
      :symmetric_ports,
      :webhooks,
      :global_networking
    ]
  end

  @impl true
  def spawn_compute(%Spec.ComputeRequest{} = req, ctx) do
    {body, auth} = Translate.compute_request_to_pod_create(req)

    with {:ok, pod} <- Pods.create(ctx, body) do
      {:ok, Translate.pod_to_compute(pod, auth)}
    end
  end

  @impl true
  def get_compute(id, ctx) do
    with {:ok, pod} <- Pods.get(ctx, id) do
      {:ok, Translate.pod_to_compute(pod)}
    end
  end

  @impl true
  def list_compute(filters, ctx) do
    params = list_filters_to_params(filters)

    with {:ok, pods} <- Pods.list(ctx, params) do
      data = normalize_list_body(pods)
      {:ok, Enum.map(data, &Translate.pod_to_compute/1)}
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
         Atlas.Error.new(:validation,
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

    cond do
      endpoint ->
        case Jobs.cancel(ctx, endpoint, id) do
          {:ok, _} -> :ok
          err -> err
        end

      true ->
        {:error,
         Atlas.Error.new(:validation,
           provider: :runpod,
           message: "cancel_job requires :endpoint in ctx"
         )}
    end
  end

  @impl true
  def stream_job(id, ctx) do
    case Map.get(ctx, :endpoint) || Map.get(ctx, :job_endpoint) do
      nil ->
        Stream.map([{:error, Atlas.Error.new(:validation, provider: :runpod)}], & &1)

      endpoint ->
        Jobs.stream(ctx, endpoint, id)
    end
  end

  @impl true
  def list_gpu_types(ctx) do
    query = """
    query AtlasGpuTypes {
      gpuTypes {
        id
        displayName
        memoryInGb
        secureCloud
        communityCloud
        lowestPrice(input: {gpuCount: 1}) {
          minimumBidPrice
          uninterruptablePrice
        }
        stockStatus
      }
    }
    """

    with {:ok, %{"gpuTypes" => types}} <- GraphQL.query(ctx, query) do
      {:ok, Enum.map(types, &to_gpu_type/1)}
    end
  end

  @doc false
  def endpoints_module, do: Endpoints

  # --- helpers ---

  defp list_filters_to_params(filters) do
    Enum.flat_map(filters, fn
      {:status, :running} -> [desiredStatus: "RUNNING"]
      {:status, :stopped} -> [desiredStatus: "EXITED"]
      {:status, :terminated} -> [desiredStatus: "TERMINATED"]
      {:status, :failed} -> [desiredStatus: "FAILED"]
      {:name, n} when is_binary(n) -> [name: n]
      _ -> []
    end)
  end

  defp normalize_list_body(%{"pods" => pods}) when is_list(pods), do: pods
  defp normalize_list_body(%{"data" => pods}) when is_list(pods), do: pods
  defp normalize_list_body(pods) when is_list(pods), do: pods
  defp normalize_list_body(_), do: []

  defp to_gpu_type(gpu) do
    low = gpu["lowestPrice"] || %{}

    %Spec.GpuType{
      id: gpu["id"],
      provider: :runpod,
      display_name: gpu["displayName"],
      memory_gb: gpu["memoryInGb"],
      lowest_price_per_hour: low["uninterruptablePrice"],
      spot_price_per_hour: low["minimumBidPrice"],
      stock: stock_atom(gpu["stockStatus"]),
      cloud_type: derive_cloud_type(gpu),
      raw: gpu
    }
  end

  defp stock_atom("High"), do: :high
  defp stock_atom("Medium"), do: :medium
  defp stock_atom("Low"), do: :low
  defp stock_atom("Unavailable"), do: :unavailable
  defp stock_atom(_), do: :unknown

  defp derive_cloud_type(%{"secureCloud" => true, "communityCloud" => true}), do: :any
  defp derive_cloud_type(%{"secureCloud" => true}), do: :secure
  defp derive_cloud_type(%{"communityCloud" => true}), do: :community
  defp derive_cloud_type(_), do: :any
end
