defmodule ExAtlas.Providers.RunPod.Translate do
  @moduledoc """
  Translation layer between ExAtlas normalized specs and RunPod's native
  REST payloads.

  All functions are pure. Keeping translation in one place means changes to
  RunPod's schema never leak into the `ExAtlas.Providers.RunPod` facade or the
  `ExAtlas.Spec.*` structs.
  """

  alias ExAtlas.Auth.Token, as: AuthToken
  alias ExAtlas.Providers.RunPod.Client
  alias ExAtlas.Spec

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
        "dataCenterIds" => if(req.region_hints == [], do: nil, else: req.region_hints),
        "dockerStartCmd" => docker_start_cmd(req)
      }
      |> Map.merge(stringify(req.provider_opts))
      |> drop_nils()

    {body, auth_handle}
  end

  @doc """
  Turn RunPod's pod response body into an `ExAtlas.Spec.Compute`.

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

  @doc "Turn a RunPod job response into an `ExAtlas.Spec.Job`."
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

  # --- start command + self-termination ---

  # RunPod treats an absent and an empty `dockerStartCmd` alike: the image's own
  # CMD runs. Wrapping an empty command would fire the trap immediately and
  # delete the pod before anything ran, so both mean "leave it unset".
  defp docker_start_cmd(%Spec.ComputeRequest{command: nil}), do: nil
  defp docker_start_cmd(%Spec.ComputeRequest{command: []}), do: nil
  defp docker_start_cmd(%Spec.ComputeRequest{command: cmd, self_terminate: false}), do: cmd

  defp docker_start_cmd(%Spec.ComputeRequest{command: cmd}),
    do: ["sh", "-c", self_terminating(cmd)]

  # A pod whose start command has exited does not stop: RunPod's REST v1 `Pod`
  # schema carries no container state — no `runtime`, no `currentStatus`, no
  # exit code — and `desiredStatus` is a *desired* state that changes only when
  # somebody asks. So the pod keeps reporting `RUNNING` and keeps billing, and
  # no amount of polling `GET /pods/:id` can tell that the work is done.
  #
  # The only party that knows the container ended is the container. RunPod
  # injects `RUNPOD_POD_ID` and a pod-scoped `RUNPOD_API_KEY` into every
  # container, so it can delete itself with no secret of ours travelling to the
  # pod. `trap … EXIT INT TERM` means a crash and a signal clean up too, not
  # just a clean exit.
  #
  # `curl` rather than `runpodctl`: curl is in nearly every base image and
  # runpodctl in nearly none. An image with neither wants
  # `self_terminate: false` and the orchestrator's `:max_runtime_ms` backstop.
  #
  # What this cannot cover: SIGKILL, the OOM killer, and a wedged process —
  # nothing runs in the container at all in those cases. That is precisely the
  # set `ExAtlas.Orchestrator.run_task/1`'s deadline exists for, which is why
  # the two mechanisms are both required rather than alternatives.
  defp self_terminating(command) do
    url = "#{Client.management_url()}/pods/$RUNPOD_POD_ID"

    "atlas_self_terminate() { curl -sS -X DELETE " <>
      "-H \"Authorization: Bearer $RUNPOD_API_KEY\" \"#{url}\"; }; " <>
      "trap atlas_self_terminate EXIT INT TERM; " <> shell_join(command)
  end

  defp shell_join(command), do: command |> Enum.map_join(" ", &shell_quote/1)

  # Single-quote everything and escape embedded single quotes the POSIX way, so
  # a command argument can never be read as shell syntax by the wrapper.
  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp atomize_for_runpod_env(env) when is_map(env),
    do: Enum.map(env, fn {k, v} -> %{"key" => to_string(k), "value" => to_string(v)} end)

  # RunPod's `desiredStatus` enum is exactly RUNNING | EXITED | TERMINATED —
  # and it is a *desired* state, so it changes only when somebody asks. Nothing
  # in REST v1 reports container state, which is why a pod whose
  # `dockerStartCmd` has exited still reads as RUNNING.
  #
  # A value outside the enum falls through to `:provisioning` on purpose: an
  # unclassifiable pod is not a dead one, and `UpstreamStatus` counts
  # `:provisioning` as alive rather than tearing the resource down.
  defp pod_status(%{"desiredStatus" => "RUNNING"}), do: :running
  defp pod_status(%{"desiredStatus" => "EXITED"}), do: :stopped
  defp pod_status(%{"desiredStatus" => "TERMINATED"}), do: :terminated
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

  # RunPod's REST v1 `Pod` schema has no `createdAt`. Its only machine-readable
  # timestamp is `lastStartedAt` ("The UTC timestamp when a Pod was last
  # started"); `lastStatusChange` is prose, not a date. So last-start is what
  # `Compute.created_at` can honestly report — and it is the better input for
  # the question the field is actually asked, `Reaper` deciding whether a
  # resource is too young to judge: a pod that was just (re)started is freshly
  # rented no matter when its record was first written.
  defp parse_created_at(%{"lastStartedAt" => s}) when is_binary(s) do
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
