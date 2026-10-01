defmodule ExAtlas.Providers.RunPod.Translate do
  @moduledoc """
  Translation layer between ExAtlas normalized specs and RunPod's native
  REST payloads.

  All functions are pure. Keeping translation in one place means changes to
  RunPod's schema never leak into the `ExAtlas.Providers.RunPod` facade or the
  `ExAtlas.Spec.*` structs.
  """

  alias ExAtlas.Auth.Token, as: AuthToken
  alias ExAtlas.Callback
  alias ExAtlas.Providers.RunPod.Client
  alias ExAtlas.Spec

  # v2 requires a name. This one never starts with the Reaper's default
  # `"atlas-"` prefix, so an unnamed pod is never reaped as an orphan.
  @default_pod_name "ex-atlas-pod"

  # v1's default `volumeMountPath`; v2 makes the path required.
  @mount_path "/workspace"

  # v1's default `containerDiskInGb`. The 2026-09-30 probe showed v2 refusing a
  # body with no `disk`, although the docs mark it optional.
  @default_disk_gb 50

  @doc """
  Turn a `ComputeRequest` into a REST v2 `CreatePodRequest` body for
  `POST /v2/pods`.

  When `request.auth == :bearer`, also mints a token and returns it so the
  caller can thread it into the resulting `Compute` struct.

  Returns `{body, auth_handle_or_nil}`.
  """
  @spec compute_request_to_pod_create(Spec.ComputeRequest.t()) :: {map(), map() | nil}
  def compute_request_to_pod_create(%Spec.ComputeRequest{} = req) do
    {auth_env, auth_handle} = build_auth(req.auth)

    env =
      req.env
      |> Map.merge(auth_env)
      |> Map.merge(callback_env(req.callback))
      |> Map.new(fn {k, v} -> {to_string(k), to_string(v)} end)

    body =
      %{
        "name" => req.name || @default_pod_name,
        "image" => req.image,
        "gpu" => %{"id" => gpu_type_id!(req.gpu), "count" => req.gpu_count},
        "cloud" => cloud(req.cloud_type),
        "ports" => pod_ports_field(req),
        "env" => env,
        "disk" => pod_disk(req),
        "mounts" => mounts(req),
        "templateId" => req.template_id,
        "dataCenterIds" => if(req.region_hints == [], do: nil, else: req.region_hints),
        "cmd" => start_cmd(req)
      }
      |> deep_merge(deep_stringify(req.provider_opts))
      |> drop_nils()

    {body, auth_handle}
  end

  @doc """
  Turn a REST v2 `Pod` body into an `ExAtlas.Spec.Compute`.

  Optional `auth` is threaded through unchanged from the spawn path.
  """
  @spec pod_to_compute(map(), map() | nil) :: Spec.Compute.t()
  def pod_to_compute(pod, auth \\ nil) when is_map(pod) do
    %Spec.Compute{
      id: Map.get(pod, "id"),
      provider: :runpod,
      status: pod_status(Map.get(pod, "status")),
      public_ip: public_ip(pod),
      ports: pod_ports(pod),
      gpu_type: gpu(pod)["id"],
      gpu_count: gpu(pod)["count"] || 1,
      cost_per_hour: Map.get(pod, "cost"),
      region: Map.get(pod, "dataCenterId"),
      image: Map.get(pod, "image"),
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

  # v2 has no "any cloud" value. Omitting the field takes Runpod's default,
  # SECURE.
  # With a `template_id`, v2 applies body fields over the template's own. An
  # empty `ports` list or the default `disk` would replace the template's, so
  # both stay out of the body until the caller sets them.
  defp pod_ports_field(%Spec.ComputeRequest{template_id: id, ports: []}) when is_binary(id),
    do: nil

  defp pod_ports_field(%Spec.ComputeRequest{ports: ports}), do: Enum.map(ports, &format_port/1)

  defp pod_disk(%Spec.ComputeRequest{template_id: id, container_disk_gb: nil}) when is_binary(id),
    do: nil

  defp pod_disk(%Spec.ComputeRequest{container_disk_gb: gb}), do: gb || @default_disk_gb

  defp cloud(:any), do: nil
  defp cloud(:secure), do: "SECURE"
  defp cloud(:community), do: "COMMUNITY"

  defp mounts(%Spec.ComputeRequest{volume_gb: nil, network_volume_id: nil}), do: nil

  defp mounts(%Spec.ComputeRequest{} = req) do
    %{
      "persistent" => req.volume_gb && %{"size" => req.volume_gb, "path" => @mount_path},
      "network" =>
        req.network_volume_id && [%{"volumeId" => req.network_volume_id, "path" => @mount_path}]
    }
    |> drop_nils()
  end

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

  # An absent and an empty `cmd` alike leave the image's own CMD to run.
  # Wrapping an empty command would fire the trap immediately and delete the
  # pod before anything ran, so both mean "leave it unset".
  defp start_cmd(%Spec.ComputeRequest{command: nil}), do: nil
  defp start_cmd(%Spec.ComputeRequest{command: []}), do: nil

  # Nothing to trap for: no self-termination asked for and nothing to report.
  defp start_cmd(%Spec.ComputeRequest{command: cmd, self_terminate: false, callback: nil}),
    do: cmd

  defp start_cmd(%Spec.ComputeRequest{command: cmd} = req),
    do: ["sh", "-c", wrapped(req, cmd)]

  # Nothing outside the container learns the command's exit code: REST v2's
  # `runtime` carries uptime and utilisation, not container state, and under
  # v1 a pod whose command exited went on reading `RUNNING` and billing.
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
  # `atlas_code=$?` must be the very first thing in the trap: anything else runs
  # first and clobbers the status we are trying to report.
  #
  # The finish POST goes *before* the DELETE, and swallows its own failure, for
  # two reasons. It has to be a marker written while the pod still exists, so a
  # later disappearance is no longer ambiguous — that is the spot fix. And the
  # DELETE is the line that stops the meter, so an unreachable callback host
  # must never be able to skip it. `-m` bounds the same risk in time.
  defp wrapped(req, command) do
    body =
      [finish_report(req.callback), self_delete(req.self_terminate)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    "atlas_self_terminate() { atlas_code=$?; #{body} }; " <>
      "trap atlas_self_terminate EXIT INT TERM; " <> shell_join(command)
  end

  defp self_delete(false), do: nil

  defp self_delete(true) do
    url = "#{Client.management_url()}/pods/$RUNPOD_POD_ID"

    "curl -sS -m 30 -X DELETE -H \"Authorization: Bearer $RUNPOD_API_KEY\" \"#{url}\";"
  end

  defp finish_report(nil), do: nil

  # Every value here comes from the container's own environment rather than
  # being interpolated into the script, so a callback URL can never be read as
  # shell syntax.
  defp finish_report(%{}) do
    ~s(curl -sS -m 10 -X POST ) <>
      ~s(-H "Authorization: Bearer $ATLAS_CALLBACK_TOKEN" ) <>
      ~s(-H "Content-Type: application/json" ) <>
      ~s(-d "{\\"exit_code\\":$atlas_code}" ) <>
      ~s("$ATLAS_CALLBACK_URL/finish" || true;)
  end

  defp shell_join(command), do: command |> Enum.map_join(" ", &shell_quote/1)

  # Single-quote everything and escape embedded single quotes the POSIX way, so
  # a command argument can never be read as shell syntax by the wrapper.
  defp shell_quote(arg), do: "'" <> String.replace(arg, "'", "'\\''") <> "'"

  defp pod_status("RUNNING"), do: :running
  defp pod_status("EXITED"), do: :stopped
  defp pod_status("ERROR"), do: :failed
  defp pod_status("TERMINATED"), do: :terminated

  # PROVISIONING and STARTING land here, and so does any status outside the
  # v2 enum, on purpose: an unclassifiable pod is not a dead one, and
  # `UpstreamStatus` counts `:provisioning` as alive rather than tearing the
  # resource down.
  defp pod_status(_), do: :provisioning

  # `ports` is what the pod was asked to expose; `runtime.ports` adds the
  # public port and IP of each TCP mapping once the pod is RUNNING (it is null
  # otherwise, and lists no HTTP ports at all).
  defp pod_ports(%{"id" => pod_id, "ports" => specs} = pod) when is_list(specs) do
    live = pod |> runtime_ports() |> Map.new(&{&1["private"], &1})

    Enum.flat_map(specs, fn spec ->
      with true <- is_binary(spec),
           [port_str, type] <- String.split(spec, "/", parts: 2),
           {port, ""} <- Integer.parse(port_str) do
        mapping = Map.get(live, port, %{})
        protocol = protocol_atom(type)
        external = mapping["public"]

        [
          %{
            internal: port,
            external: external,
            protocol: protocol,
            url: port_url(pod_id, protocol, port, mapping["ip"], external)
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp pod_ports(_), do: []

  defp runtime_ports(%{"runtime" => %{"ports" => ports}}) when is_list(ports),
    do: Enum.filter(ports, &is_map/1)

  defp runtime_ports(_), do: []

  # A status poller runs `pod_to_compute/2` in a loop, so a field of the wrong
  # type reads as absent rather than raising.
  defp gpu(%{"gpu" => %{} = gpu}), do: gpu
  defp gpu(_pod), do: %{}

  defp public_ip(pod), do: pod |> runtime_ports() |> Enum.find_value(& &1["ip"])

  defp protocol_atom(type) when is_binary(type) do
    case String.downcase(type) do
      t when t in ["http", "https"] -> :http
      _ -> :tcp
    end
  end

  defp protocol_atom(_), do: :tcp

  defp port_url(pod_id, :http, port, _ip, _external) when is_binary(pod_id),
    do: "https://#{pod_id}-#{port}.proxy.runpod.net"

  defp port_url(_pod_id, :tcp, _port, ip, external) when is_binary(ip) and is_integer(external),
    do: "tcp://#{ip}:#{external}"

  defp port_url(_, _, _, _, _), do: nil

  # `startedAt` first: the Reaper asks whether a resource is too young to
  # judge, and a pod that was just (re)started is freshly rented no matter when
  # its record was first written. v1 answered the same question with
  # `lastStartedAt`.
  defp parse_created_at(pod) do
    Enum.find_value(["startedAt", "createdAt"], fn key ->
      with s when is_binary(s) <- Map.get(pod, key),
           {:ok, dt, _} <- DateTime.from_iso8601(s) do
        dt
      else
        _ -> nil
      end
    end)
  end

  # --- job helpers ---

  defp job_status("IN_QUEUE"), do: :in_queue
  defp job_status("IN_PROGRESS"), do: :in_progress
  defp job_status("COMPLETED"), do: :completed
  defp job_status("FAILED"), do: :failed
  defp job_status("CANCELLED"), do: :cancelled
  defp job_status("TIMED_OUT"), do: :timed_out
  defp job_status(_), do: :in_queue

  defp callback_env(nil), do: %{}
  defp callback_env(%{} = callback), do: Callback.env(callback)

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

  defp deep_stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), deep_stringify(v)} end)

  defp deep_stringify(other), do: other

  # `provider_opts` reach into nested objects: `%{"gpu" => %{"minCudaVersion"
  # => "12.1"}}` adds to `gpu` and keeps its `id`.
  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> deep_merge(l, r)
      _key, _l, r -> r
    end)
  end

  defp drop_nils(map) when is_map(map),
    do: :maps.filter(fn _, v -> v != nil end, map)

  @doc """
  Merge the SECURE and COMMUNITY catalog reads into `[Spec.GpuType]`.

  A GPU listed in one read only still appears. `lowest_price_per_hour` is the
  lower list price of the clouds the GPU is offered on, `stock` the best level
  of those clouds, and `nil` and `:unavailable` when it is offered on neither.
  Runpod sells no spot pods, so `spot_price_per_hour` is always `nil`.
  """
  @spec gpu_types([map()], [map()]) :: [Spec.GpuType.t()]
  def gpu_types(secure_entries, community_entries) do
    secure = Map.new(secure_entries, &{&1["id"], &1})
    community = Map.new(community_entries, &{&1["id"], &1})

    ids =
      Enum.uniq(Enum.map(secure_entries, & &1["id"]) ++ Enum.map(community_entries, & &1["id"]))

    Enum.map(ids, &gpu_type(secure[&1], community[&1]))
  end

  defp gpu_type(secure, community) do
    entry = secure || community
    secure? = entry["secure"] == true
    community? = entry["community"] == true

    offered =
      [{secure?, secure, "secure"}, {community?, community, "community"}]
      |> Enum.filter(&elem(&1, 0))

    %Spec.GpuType{
      id: entry["id"],
      provider: :runpod,
      display_name: entry["name"],
      memory_gb: entry["memory"],
      lowest_price_per_hour:
        offered |> Enum.map(fn {_, _, cloud} -> get_in(entry, ["price", cloud]) end) |> lowest(),
      spot_price_per_hour: nil,
      stock: offered |> Enum.map(fn {_, e, _} -> e && e["availability"] end) |> best_stock(),
      cloud_type: gpu_cloud_type(secure?, community?),
      raw: %{"SECURE" => secure, "COMMUNITY" => community}
    }
  end

  defp lowest(prices), do: prices |> Enum.filter(&is_number/1) |> Enum.min(fn -> nil end)

  defp best_stock([]), do: :unavailable

  defp best_stock(levels) do
    levels |> Enum.map(&stock_atom/1) |> Enum.max_by(&stock_rank/1)
  end

  defp stock_atom("HIGH"), do: :high
  defp stock_atom("MEDIUM"), do: :medium
  defp stock_atom("LOW"), do: :low
  defp stock_atom("NONE"), do: :unavailable
  defp stock_atom(_), do: :unknown

  defp stock_rank(:high), do: 4
  defp stock_rank(:medium), do: 3
  defp stock_rank(:low), do: 2
  defp stock_rank(:unavailable), do: 1
  defp stock_rank(:unknown), do: 0

  defp gpu_cloud_type(true, false), do: :secure
  defp gpu_cloud_type(false, true), do: :community
  defp gpu_cloud_type(_, _), do: :any

  @doc """
  Build the `POST /network-volumes` body. `type` is sent only when the request
  names a tier, so RunPod picks its own default otherwise. `provider_opts` merge
  over the body.
  """
  @spec network_volume_request_to_body(Spec.NetworkVolumeRequest.t()) :: map()
  def network_volume_request_to_body(%Spec.NetworkVolumeRequest{} = req) do
    %{
      "name" => req.name,
      "size" => req.size_gb,
      "dataCenter" => req.region,
      "type" => volume_type(req.tier)
    }
    |> drop_nils()
    |> Map.merge(stringify(req.provider_opts))
  end

  @doc "Normalize a RunPod network volume body."
  @spec network_volume_to_spec(map()) :: Spec.NetworkVolume.t()
  def network_volume_to_spec(%{} = raw) do
    %Spec.NetworkVolume{
      id: raw["id"],
      provider: :runpod,
      name: raw["name"],
      size_gb: raw["size"],
      region: raw["dataCenter"],
      tier: tier_from_type(raw["type"]),
      raw: raw
    }
  end

  defp volume_type(:standard), do: "STANDARD"
  defp volume_type(:high_performance), do: "HIGH_PERFORMANCE"
  defp volume_type(nil), do: nil

  defp tier_from_type("STANDARD"), do: :standard
  defp tier_from_type("HIGH_PERFORMANCE"), do: :high_performance
  defp tier_from_type(_), do: nil
end
