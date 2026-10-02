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

      [:serverless, :network_volumes, :manage_network_volumes, :manage_templates,
       :manage_endpoints, :billing, :http_proxy, :raw_tcp, :symmetric_ports, :webhooks,
       :global_networking, :self_terminate]

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

  alias ExAtlas.Providers.RunPod.{
    Billing,
    Catalog,
    Endpoints,
    Jobs,
    NetworkVolumes,
    Pods,
    Templates,
    Translate
  }

  alias ExAtlas.Spec

  @impl true
  def capabilities do
    [
      :serverless,
      :network_volumes,
      :manage_network_volumes,
      :manage_templates,
      :manage_endpoints,
      :billing,
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

      # `raw` stays nil: a list of pod bodies would carry every pod's env.
      {:ok, _other} ->
        {:error,
         ExAtlas.Error.new(:provider,
           provider: :runpod,
           message: "unexpected body for GET /pods/#{id}",
           raw: nil
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

  @impl true
  def list_network_volumes(ctx) do
    with {:ok, volumes} <- NetworkVolumes.list(ctx) do
      {:ok, Enum.map(volumes, &Translate.network_volume_to_spec/1)}
    end
  end

  @impl true
  def get_network_volume(id, ctx) do
    with {:ok, volume} <- NetworkVolumes.get(ctx, id),
         do: volume_spec(volume, "GET /network-volumes/#{id}")
  end

  @impl true
  def create_network_volume(%Spec.NetworkVolumeRequest{region: nil}, _ctx) do
    {:error,
     ExAtlas.Error.new(:validation,
       provider: :runpod,
       message: "RunPod needs a :region (its dataCenter) to create a network volume"
     )}
  end

  def create_network_volume(%Spec.NetworkVolumeRequest{} = req, ctx) do
    body = Translate.network_volume_request_to_body(req)

    with {:ok, volume} <- NetworkVolumes.create(ctx, body),
         do: volume_spec(volume, "POST /network-volumes")
  end

  @impl true
  def delete_network_volume(id, ctx) do
    case NetworkVolumes.delete(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def list_templates(ctx) do
    with {:ok, templates} <- Templates.list(ctx) do
      {:ok, Enum.map(templates, &Translate.template_to_spec/1)}
    end
  end

  @impl true
  def get_template(id, ctx) do
    with {:ok, template} <- Templates.get(ctx, id),
         do: template_spec(template, "GET /templates/#{id}")
  end

  @impl true
  def create_template(%Spec.TemplateRequest{} = req, ctx) do
    body = Translate.template_request_to_body(req)

    with {:ok, template} <- Templates.create(ctx, body),
         do: template_spec(template, "POST /templates")
  end

  @impl true
  def delete_template(id, ctx) do
    case Templates.delete(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  # With no `:from`/`:to` the request carries neither `startTime` nor
  # `endTime`, and RunPod covers its own default, the last 30 days.
  def compute_spend(id, opts, ctx) do
    params =
      [podId: id] ++
        for {key, param} <- [from: :startTime, to: :endTime],
            %DateTime{} = at <- [opts[key]],
            do: {param, DateTime.to_iso8601(at)}

    with {:ok, body} <- Billing.pods(ctx, params) do
      case Translate.pod_billing_to_spend(body, id) do
        {:ok, spend} -> {:ok, spend}
        :error -> unexpected_body(body, "GET /billing/pods")
      end
    end
  end

  @impl true
  def list_endpoints(ctx) do
    with {:ok, endpoints} <- Endpoints.list(ctx) do
      {:ok, Enum.map(endpoints, &Translate.endpoint_to_spec/1)}
    end
  end

  @impl true
  def get_endpoint(id, ctx) do
    with {:ok, endpoint} <- Endpoints.get(ctx, id),
         do: endpoint_spec(endpoint, "GET /serverless/#{id}")
  end

  @impl true
  def delete_endpoint(id, ctx) do
    case Endpoints.delete(ctx, id) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # --- helpers ---

  defp volume_spec(%{} = volume, _call), do: {:ok, Translate.network_volume_to_spec(volume)}

  defp volume_spec(other, call), do: unexpected_body(other, call)

  defp template_spec(%{} = template, _call), do: {:ok, Translate.template_to_spec(template)}

  # A template body can carry env secrets, so the error keeps it out of `raw`.
  defp template_spec(_other, call), do: unexpected_body(nil, call)

  # An endpoint body carries env secrets, so the error keeps it out of `raw`.
  defp endpoint_spec(%{} = endpoint, _call), do: {:ok, Translate.endpoint_to_spec(endpoint)}
  defp endpoint_spec(_other, call), do: unexpected_body(nil, call)

  defp unexpected_body(other, call) do
    {:error,
     ExAtlas.Error.new(:provider,
       provider: :runpod,
       message: "unexpected body for #{call}",
       raw: other
     )}
  end

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
