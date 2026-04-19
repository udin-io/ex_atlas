defmodule Atlas.Providers.RunPod.Translate do
  @moduledoc """
  Translation layer between Atlas normalized specs and RunPod's native
  REST payloads.

  All functions are pure. Keeping translation in one place means changes to
  RunPod's schema never leak into the `Atlas.Providers.RunPod` facade or the
  `Atlas.Spec.*` structs.
  """

  alias Atlas.Auth.Token, as: AuthToken
  alias Atlas.Spec

  @doc """
  Turn a `ComputeRequest` into a body ready for `POST /pods`.

  When `request.auth == :bearer`, also mints a token and returns it so the
  caller can thread it into the resulting `Compute` struct.

  Returns `{body, auth_handle_or_nil}`.
  """
  @spec compute_request_to_pod_create(Spec.ComputeRequest.t()) :: {map(), map() | nil}
  def compute_request_to_pod_create(%Spec.ComputeRequest{} = req) do
    {auth_env, auth_handle} = build_auth(req.auth)
    env = req.env |> Map.merge(auth_env) |> atomize_for_runpod_env()

    body =
      %{
        "cloudType" => cloud_type(req.cloud_type),
        "computeType" => "GPU",
        "gpuCount" => req.gpu_count,
        "gpuTypeIds" => [gpu_type_id!(req.gpu)],
        "interruptible" => req.spot,
        "imageName" => req.image,
        "ports" => Enum.map(req.ports, &format_port/1),
        "env" => env,
        "name" => req.name,
        "containerDiskInGb" => req.container_disk_gb,
        "volumeInGb" => req.volume_gb,
        "networkVolumeId" => req.network_volume_id,
        "templateId" => req.template_id,
        "dataCenterIds" => if(req.region_hints == [], do: nil, else: req.region_hints)
      }
      |> Map.merge(stringify(req.provider_opts))
      |> drop_nils()

    {body, auth_handle}
  end

  @doc """
  Turn RunPod's pod response body into an `Atlas.Spec.Compute`.

  Optional `auth` is threaded through unchanged from the spawn path.
  """
  @spec pod_to_compute(map(), map() | nil) :: Spec.Compute.t()
  def pod_to_compute(pod, auth \\ nil) when is_map(pod) do
    %Spec.Compute{
      id: Map.get(pod, "id") || Map.get(pod, "podId"),
      provider: :runpod,
      status: pod_status(pod),
      public_ip: Map.get(pod, "publicIp"),
      ports: pod_ports(pod),
      gpu_type: first_gpu_type(pod),
      gpu_count: Map.get(pod, "gpuCount", 1),
      cost_per_hour: Map.get(pod, "costPerHr") || Map.get(pod, "adjustedCostPerHr"),
      region: Map.get(pod, "dataCenterId"),
      image: Map.get(pod, "imageName"),
      name: Map.get(pod, "name"),
      auth: auth,
      created_at: parse_created_at(pod),
      raw: pod
    }
  end

  @doc "Turn a JobRequest into a RunPod runsync/run body."
  @spec job_request_to_body(Spec.JobRequest.t()) :: map()
  def job_request_to_body(%Spec.JobRequest{} = req) do
    %{
      "input" => req.input,
      "webhook" => req.webhook,
      "policy" => stringify(req.policy)
    }
    |> Map.merge(stringify(req.provider_opts))
    |> drop_nils()
  end

  @doc "Turn a RunPod job response into an `Atlas.Spec.Job`."
  @spec job_response_to_job(map(), String.t() | nil) :: Spec.Job.t()
  def job_response_to_job(body, endpoint \\ nil) when is_map(body) do
    %Spec.Job{
      id: Map.get(body, "id"),
      provider: :runpod,
      endpoint: endpoint,
      status: job_status(Map.get(body, "status")),
      output: Map.get(body, "output"),
      error: Map.get(body, "error"),
      execution_time_ms: Map.get(body, "executionTime"),
      delay_time_ms: Map.get(body, "delayTime"),
      raw: body
    }
  end

  # --- pod helpers ---

  defp cloud_type(:any), do: "ALL"
  defp cloud_type(:secure), do: "SECURE"
  defp cloud_type(:community), do: "COMMUNITY"

  defp gpu_type_id!(canonical) do
    case Spec.GpuCatalog.for_provider(canonical, :runpod) do
      {:ok, id} ->
        id

      {:error, _} ->
        raise ArgumentError,
              "RunPod has no mapping for GPU atom #{inspect(canonical)}. " <>
                "Known: #{inspect(Spec.GpuCatalog.supported_gpus(:runpod))}"
    end
  end

  defp format_port({port, :http}), do: "#{port}/http"
  defp format_port({port, :tcp}), do: "#{port}/tcp"

  defp atomize_for_runpod_env(env) when is_map(env),
    do: Enum.map(env, fn {k, v} -> %{"key" => to_string(k), "value" => to_string(v)} end)

  defp pod_status(%{"desiredStatus" => "RUNNING"}), do: :running
  defp pod_status(%{"desiredStatus" => "EXITED"}), do: :stopped
  defp pod_status(%{"desiredStatus" => "TERMINATED"}), do: :terminated
  defp pod_status(%{"desiredStatus" => "FAILED"}), do: :failed
  defp pod_status(_), do: :provisioning

  defp pod_ports(%{"portMappings" => mappings}) when is_list(mappings) do
    Enum.map(mappings, fn m ->
      internal = m["privatePort"] || m["internal"]
      external = m["publicPort"] || m["external"]
      protocol = m["type"] |> to_string() |> String.downcase() |> protocol_atom()
      %{internal: internal, external: external, protocol: protocol, url: proxy_url(m, protocol)}
    end)
  end

  defp pod_ports(%{"id" => pod_id, "ports" => ports}) when is_binary(ports) do
    ports
    |> String.split(",", trim: true)
    |> Enum.map(fn spec ->
      [port_str, type] = spec |> String.trim() |> String.split("/", parts: 2)
      {port, _} = Integer.parse(port_str)
      protocol = protocol_atom(type)

      %{
        internal: port,
        external: nil,
        protocol: protocol,
        url: http_proxy_url(pod_id, port, protocol)
      }
    end)
  end

  defp pod_ports(_), do: []

  defp protocol_atom("http"), do: :http
  defp protocol_atom("https"), do: :http
  defp protocol_atom("tcp"), do: :tcp
  defp protocol_atom(_), do: :tcp

  defp proxy_url(%{"publicIp" => ip, "publicPort" => port}, :tcp) when is_binary(ip),
    do: "tcp://#{ip}:#{port}"

  defp proxy_url(%{"podId" => pod_id, "privatePort" => port}, :http),
    do: http_proxy_url(pod_id, port, :http)

  defp proxy_url(_, _), do: nil

  defp http_proxy_url(pod_id, port, :http) when is_binary(pod_id),
    do: "https://#{pod_id}-#{port}.proxy.runpod.net"

  defp http_proxy_url(_, _, _), do: nil

  defp first_gpu_type(%{"gpuTypeIds" => [first | _]}), do: first
  defp first_gpu_type(%{"gpuTypeId" => id}), do: id
  defp first_gpu_type(%{"machine" => %{"gpuTypeId" => id}}), do: id
  defp first_gpu_type(_), do: nil

  defp parse_created_at(%{"createdAt" => s}) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_created_at(_), do: nil

  # --- job helpers ---

  defp job_status("IN_QUEUE"), do: :in_queue
  defp job_status("IN_PROGRESS"), do: :in_progress
  defp job_status("COMPLETED"), do: :completed
  defp job_status("FAILED"), do: :failed
  defp job_status("CANCELLED"), do: :cancelled
  defp job_status("TIMED_OUT"), do: :timed_out
  defp job_status(_), do: :in_queue

  # --- auth helpers ---

  defp build_auth(:none), do: {%{}, nil}

  defp build_auth(:bearer) do
    mint = AuthToken.mint()
    {mint.env, %{scheme: :bearer, token: mint.token, hash: mint.hash, header: mint.header}}
  end

  defp build_auth(:signed_url) do
    secret = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    {%{"ATLAS_SIGNING_SECRET" => secret},
     %{scheme: :signed_url, token: secret, hash: nil, header: nil}}
  end

  # --- generic helpers ---

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp drop_nils(map) when is_map(map),
    do: :maps.filter(fn _, v -> v != nil end, map)
end
