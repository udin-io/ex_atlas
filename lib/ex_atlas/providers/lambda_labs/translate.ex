defmodule ExAtlas.Providers.LambdaLabs.Translate do
  @moduledoc """
  Translation between ExAtlas specs and Lambda Cloud API v1 bodies.

  Lambda runs a VM, not a container. A spawn with an `:image` hands the VM a
  cloud-init `user_data` script that runs the image with `docker run`, and
  tags the instance so a later read can rebuild the `Compute`:

  | Tag | Value | Read into |
  |---|---|---|
  | `atlas-ports` | `8000/http,22/tcp` | `ports`, with URLs from the instance `ip` |
  | `atlas-created-at` | ISO 8601 at launch | `created_at`; Lambda reports no creation time |
  | `atlas-image` | the image, when 128 characters or fewer | `image` |

  Every function here is pure, except `launch_parts/2`, which mints the
  `:auth` credential, and `instance_to_compute/2`, which reads an
  `atlas-created-at` more than ten minutes ahead of the clock as absent.
  """

  alias ExAtlas.{Error, Secret, Spec}
  alias ExAtlas.Providers.Shell

  @tag_ports "atlas-ports"
  @tag_created_at "atlas-created-at"
  @tag_image "atlas-image"

  # Lambda's tag values hold at most 128 characters.
  @max_tag_value 128

  # How far ahead of this node's clock an `atlas-created-at` tag may read.
  @max_clock_skew_s 10 * 60

  # Lambda caps `user_data` at "1MB"; we take the smaller reading.
  @max_user_data_bytes 1_000_000

  @shell_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # Names bash keeps for itself. `export` of a readonly one stops the script
  # before `docker run`; bash rewrites or drops a special one, so the
  # container would get another value. `BASH_*` and `COMP_*` are refused as
  # prefixes, which covers bash 5's `BASH_ARGV0`, `BASH_SUBSHELL` and the rest.
  @bash_names ~w(UID EUID PPID SHELLOPTS BASHOPTS RANDOM SRANDOM SECONDS LINENO GROUPS
                 FUNCNAME HISTCMD OPTIND DIRSTACK PIPESTATUS BASHPID EPOCHSECONDS
                 EPOCHREALTIME)

  # How long the script waits for the Docker daemon, which cloud-init can
  # reach before `docker.service` is up: 90 tries, 2 s apart.
  @docker_wait_tries 90

  @typedoc """
  What a launch needs from the request alone: the `user_data` script as a
  `Secret` (`nil` with no image), the tags, and the `Compute.auth` handle as
  a `Secret`, since its token is a credential and `parts` is an argument of
  the launch functions a crash would print.
  """
  @type parts :: %{
          user_data: Secret.t() | nil,
          tags: [%{String.t() => String.t()}],
          auth: Secret.t() | nil
        }

  @doc """
  Validate `request` and build the request-only parts of the launch body.

  Returns `{:error, %ExAtlas.Error{kind: :validation}}`, naming no value, for:

    * an env name that is not a shell identifier, starts with `DOCKER_` or
      `LD_`, which the host's docker client and loader read, or is one bash
      keeps for itself (`UID`, `RANDOM`, `BASH_*`, ...);
    * a value or `:image` holding a NUL byte or not UTF-8;
    * an `:image` that starts with `-`;
    * a port that is not `{1..65535, :http | :tcp}`, or ports too many for a
      #{@max_tag_value}-character tag;
    * a `:command` argument holding a NUL byte or not UTF-8;
    * `:env`, `:s3`, `:auth`, `:ports`, `:command` or a callback without an
      `:image`;
    * a script over #{@max_user_data_bytes} bytes.
  """
  @spec launch_parts(Spec.ComputeRequest.t(), DateTime.t()) ::
          {:ok, parts()} | {:error, Error.t()}
  def launch_parts(%Spec.ComputeRequest{} = request, %DateTime{} = now) do
    with :ok <- check_container_fields(request),
         {:ok, ports} <- ports(request.ports) do
      {auth_env, auth} = ExAtlas.Auth.for_scheme(request.auth)
      env = request |> Spec.ComputeRequest.container_env() |> Map.merge(auth_env)

      with :ok <- check_env(env),
           {:ok, user_data} <- user_data(request, env, ports),
           {:ok, tags} <- tags(request.image, ports, now) do
        {:ok,
         %{
           user_data: Secret.wrap(user_data),
           tags: tags,
           auth: Secret.wrap(auth)
         }}
      end
    end
  end

  @doc """
  The `POST /instance-operations/launch` body. `user_data` stays an
  `ExAtlas.Secret` until `LambdaLabs.Client.post/4` encodes it.
  """
  @spec launch_body(Spec.ComputeRequest.t(), parts(), String.t(), String.t(), String.t()) :: map()
  def launch_body(%Spec.ComputeRequest{} = request, parts, instance_type, region, ssh_key) do
    %{
      "region_name" => region,
      "instance_type_name" => instance_type,
      "ssh_key_names" => [ssh_key],
      "name" => request.name,
      "user_data" => parts.user_data,
      "tags" => parts.tags
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The instance type to launch: `provider_opts.instance_type` when set, else
  the catalog's 1x name for `:gpu` with `1x` swapped for `:gpu_count`
  (`gpu_8x_h100_sxm5`). `types` is the `GET /instance-types` data; a name it
  does not list is `:validation`.
  """
  @spec instance_type(Spec.ComputeRequest.t(), map()) :: {:ok, String.t()} | {:error, Error.t()}
  def instance_type(%Spec.ComputeRequest{} = request, types) when is_map(types) do
    case provider_opt(request, :instance_type) do
      nil -> catalog_type(request, types)
      name when is_binary(name) -> listed_type(name, types)
      _other -> validation("provider_opts.instance_type must be a string")
    end
  end

  @doc """
  The region to launch `type_entry` in: the first of `hints` with capacity,
  else the first region with capacity. None has capacity: `:provider`.
  """
  @spec region(String.t(), map(), [String.t()]) :: {:ok, String.t()} | {:error, Error.t()}
  def region(type, %{} = type_entry, hints) do
    with_capacity =
      for %{"name" => name} when is_binary(name) <-
            List.wrap(type_entry["regions_with_capacity_available"]),
          do: name

    case Enum.find(hints, &(&1 in with_capacity)) || List.first(with_capacity) do
      nil ->
        {:error,
         Error.new(:provider,
           provider: :lambda_labs,
           message: "Lambda has no capacity for #{type} in any region"
         )}

      region ->
        {:ok, region}
    end
  end

  @doc "Turn a Lambda `Instance` into an `ExAtlas.Spec.Compute`."
  @spec instance_to_compute(map(), Spec.Compute.auth_handle() | nil) :: Spec.Compute.t()
  def instance_to_compute(%{} = instance, auth \\ nil) do
    tags = tag_map(instance["tags"])
    type = map_or_empty(instance["instance_type"])
    ip = string_or_nil(instance["ip"])

    %Spec.Compute{
      id: instance["id"],
      provider: :lambda_labs,
      status: status(instance["status"]),
      public_ip: ip,
      ports: tags |> Map.get(@tag_ports) |> parse_ports() |> Enum.map(&binding(&1, ip)),
      gpu_type: type["name"],
      gpu_count: gpu_count(type),
      cost_per_hour: price(type["price_cents_per_hour"]),
      region: map_or_empty(instance["region"])["name"],
      image: tags[@tag_image],
      name: instance["name"],
      auth: auth,
      created_at: tags[@tag_created_at] |> parse_time() |> drop_far_future(),
      # `jupyter_token`, and the URL that carries it, open the instance's
      # Jupyter.
      raw: Map.drop(instance, ["jupyter_token", "jupyter_url"])
    }
  end

  @doc """
  The `Compute` a launch returns, built from the request and the launch id.
  No `GET` follows the launch: a failed read there must not turn a rented
  instance into an error the caller drops.
  """
  @spec launched_compute(String.t(), Spec.ComputeRequest.t(), parts(), map(), String.t()) ::
          Spec.Compute.t()
  def launched_compute(id, request, parts, type_entry, region) do
    type = map_or_empty(type_entry["instance_type"])
    tags = tag_map(parts.tags)

    %Spec.Compute{
      id: id,
      provider: :lambda_labs,
      status: :provisioning,
      ports: tags |> Map.get(@tag_ports) |> parse_ports() |> Enum.map(&binding(&1, nil)),
      gpu_type: type["name"],
      gpu_count: gpu_count(type),
      cost_per_hour: price(type["price_cents_per_hour"]),
      region: region,
      image: request.image,
      name: request.name,
      auth: Secret.reveal(parts.auth),
      created_at: parse_time(tags[@tag_created_at]),
      raw: %{"instance_ids" => [id]}
    }
  end

  @doc """
  Turn the `GET /instance-types` data into `ExAtlas.Spec.GpuType`s, one per
  instance type. Stock is `:unavailable` with no region, else `:unknown`:
  Lambda says only whether a region has capacity.
  """
  @spec gpu_types(map()) :: [Spec.GpuType.t()]
  def gpu_types(types) when is_map(types) do
    types
    |> Enum.filter(fn {_name, entry} -> is_map(entry) end)
    |> Enum.map(fn {name, entry} -> gpu_type(name, entry) end)
    |> Enum.sort_by(& &1.id)
  end

  @doc "Whether `gpu_type` is an instance type of `canonical`'s family."
  @spec gpu_family?(String.t() | nil, atom()) :: boolean()
  def gpu_family?(gpu_type, canonical) when is_binary(gpu_type) do
    case family(canonical) do
      {:ok, suffix} -> Regex.match?(~r/\Agpu_\d+x_#{Regex.escape(suffix)}\z/, gpu_type)
      :error -> false
    end
  end

  def gpu_family?(_gpu_type, _canonical), do: false

  # --- launch parts ---

  defp check_container_fields(%Spec.ComputeRequest{image: image} = request)
       when is_binary(image) do
    cond do
      not String.valid?(image) ->
        validation(":image is not valid UTF-8")

      String.contains?(image, <<0>>) ->
        validation(":image holds a NUL byte, which a shell cannot carry")

      String.starts_with?(image, "-") ->
        validation(":image starts with -, which docker reads as a flag")

      true ->
        check_command(request.command || [])
    end
  end

  defp check_container_fields(request) do
    used =
      [
        env: request.env != %{},
        s3: request.s3 != nil,
        auth: request.auth != :none,
        ports: request.ports != [],
        callback: request.callback != nil,
        command: request.command not in [nil, []]
      ]
      |> Enum.filter(fn {_field, set?} -> set? end)
      |> Enum.map(fn {field, _} -> inspect(field) end)

    case used do
      [] ->
        :ok

      fields ->
        validation(
          "#{Enum.join(fields, ", ")} configure a container; Lambda runs one only " <>
            "with an :image"
        )
    end
  end

  # Lambda's body is JSON, which carries UTF-8 only, and no shell argument
  # can carry a NUL byte. The message names the position, never the value.
  defp check_command(command) do
    command
    |> Enum.with_index()
    |> Enum.find_value(:ok, fn {arg, index} ->
      if String.valid?(arg) and not String.contains?(arg, <<0>>),
        do: nil,
        else: validation(":command argument #{index} holds a NUL byte or is not valid UTF-8")
    end)
  end

  defp ports(ports) do
    Enum.reduce_while(ports, {:ok, []}, fn
      {port, protocol}, {:ok, acc}
      when is_integer(port) and port in 1..65_535 and protocol in [:http, :tcp] ->
        {:cont, {:ok, [{port, protocol} | acc]}}

      other, _acc ->
        {:halt, validation("a port must be {1..65535, :http | :tcp}, got: #{inspect(other)}")}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp check_env(env) do
    Enum.find_value(env, :ok, fn {name, value} ->
      cond do
        not Regex.match?(@shell_name, name) ->
          validation(
            "env name #{inspect(name)} is not a shell identifier ([A-Za-z_][A-Za-z0-9_]*)"
          )

        name in @bash_names or String.starts_with?(name, ["BASH_", "COMP_"]) ->
          validation(
            "env name #{inspect(name)} is a bash variable; Lambda's script cannot export it " <>
              "for docker run"
          )

        String.starts_with?(name, ["DOCKER_", "LD_"]) ->
          validation(
            "env name #{inspect(name)} would steer the host's docker client or loader; " <>
              "Lambda's script exports each variable for docker run"
          )

        String.contains?(value, <<0>>) ->
          validation("the value of #{inspect(name)} holds a NUL byte, which a shell cannot carry")

        # Lambda's body is JSON, which carries UTF-8 only.
        not String.valid?(value) ->
          validation("the value of #{inspect(name)} is not valid UTF-8")

        true ->
          nil
      end
    end)
  end

  defp user_data(%Spec.ComputeRequest{image: nil}, _env, _ports), do: {:ok, nil}

  defp user_data(%Spec.ComputeRequest{image: image} = request, env, ports) do
    names = env |> Map.keys() |> Enum.sort()

    exports = Enum.map(names, fn name -> "export #{name}=#{Shell.quote_arg(env[name])}\n" end)

    flags =
      Enum.map(ports, fn {port, _} -> " -p #{port}:#{port}" end) ++
        Enum.map(names, &" -e #{&1}")

    reporter = request.callback && finish_reporter(env)

    # Values reach `docker` through its environment, never its argv, so `ps`
    # on the instance shows names only. The script finds docker and waits for
    # its daemon before it exports the values, so a container `PATH` cannot
    # hide docker; `DOCKER_BIN` falls under the refused `DOCKER_` names. The
    # exports stay in the subshell that runs docker, so no container variable
    # steers `systemd-run` after it. No `set -x`: cloud-init logs the script's
    # output.
    script =
      IO.iodata_to_binary([
        "#!/bin/bash\n",
        "set -euo pipefail\n",
        "DOCKER_BIN=$(command -v docker)\n",
        if(reporter, do: "SYSTEMD_RUN_BIN=$(command -v systemd-run)\n", else: []),
        "for _ in $(seq 1 #{@docker_wait_tries}); do ",
        "\"$DOCKER_BIN\" info >/dev/null 2>&1 && break; sleep 2; done\n",
        if(reporter, do: reporter.write, else: []),
        "(\n",
        exports,
        "exec \"$DOCKER_BIN\" run --detach --name atlas --gpus all --restart no",
        flags,
        " ",
        Shell.quote_arg(image),
        command_args(request.command),
        # With a reporter, a failed `docker run` goes on to start the unit,
        # which reports 125 for the missing container.
        if(reporter, do: "\n) || true\n", else: "\n)\n"),
        if(reporter, do: reporter.start, else: [])
      ])

    if byte_size(script) > @max_user_data_bytes do
      validation(
        "the user_data script is #{byte_size(script)} bytes; Lambda takes at most " <>
          "#{@max_user_data_bytes}"
      )
    else
      {:ok, script}
    end
  end

  defp command_args(nil), do: []
  defp command_args([]), do: []
  defp command_args(command), do: [" ", Shell.join(command)]

  # A Lambda instance holds no key that can delete it, so the container cannot
  # end its own bill as RunPod's does. The host reports instead: a transient
  # systemd unit runs `docker wait atlas` and POSTs the exit code, and the
  # tracker deletes the instance on that report. A unit, not a wait in this
  # script, because cloud-init's final stage would wait on the whole task.
  # With no container to wait on (`docker run` failed, or a `dockerd` restart
  # removed it), the unit reports 125, docker's code for a failed run, so the
  # task ends now instead of at `max_runtime_ms`.
  #
  # The unit's script holds the callback URL and token. `printf` is a bash
  # builtin, so the token never appears on an argv; `mktemp` makes the file
  # readable by root alone, and the unit deletes it as it starts; and curl reads the `Authorization` header from
  # stdin, since the host's `ps` shows every login each process's argv.
  # `finish` is first-report-wins, so curl's retries are safe.
  defp finish_reporter(env) do
    unit_script =
      IO.iodata_to_binary([
        "#!/bin/bash\n",
        "set -uo pipefail\n",
        # bash holds the file open, so it reads the lines below after this.
        "rm -f -- \"$0\"\n",
        "ATLAS_CALLBACK_URL=",
        Shell.quote_arg(env["ATLAS_CALLBACK_URL"]),
        "\n",
        "ATLAS_CALLBACK_TOKEN=",
        Shell.quote_arg(env["ATLAS_CALLBACK_TOKEN"]),
        "\n",
        ~S"""
        code=$("$1" wait atlas) || code=125
        case "$code" in ''|*[!0-9]*) code=125 ;; esac
        printf 'Authorization: Bearer %s\n' "$ATLAS_CALLBACK_TOKEN" |
          curl -fsS -m 10 --retry 5 --retry-connrefused -H @- \
            -H 'Content-Type: application/json' -d "{\"exit_code\":$code}" \
            "$ATLAS_CALLBACK_URL/finish"
        """
      ])

    %{
      write: [
        "ATLAS_FINISH=$(mktemp \"${TMPDIR:-/tmp}/atlas-finish.XXXXXX\")\n",
        "printf '%s' ",
        Shell.quote_arg(unit_script),
        " > \"$ATLAS_FINISH\"\n"
      ],
      start:
        "exec \"$SYSTEMD_RUN_BIN\" --unit=atlas-finish --collect --quiet " <>
          "/bin/bash \"$ATLAS_FINISH\" \"$DOCKER_BIN\"\n"
    }
  end

  defp tags(image, ports, now) do
    ports_value = Enum.map_join(ports, ",", fn {port, protocol} -> "#{port}/#{protocol}" end)

    if String.length(ports_value) > @max_tag_value do
      validation(
        "the ports take #{String.length(ports_value)} characters as a Lambda tag; " <>
          "at most #{@max_tag_value} fit"
      )
    else
      {:ok,
       [
         {@tag_created_at, DateTime.to_iso8601(DateTime.truncate(now, :second))},
         {@tag_ports, ports_value},
         {@tag_image, image_tag(image)}
       ]
       |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
       |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)}
    end
  end

  defp image_tag(image) when is_binary(image) do
    if String.length(image) <= @max_tag_value, do: image
  end

  defp image_tag(nil), do: nil

  # --- instance type ---

  defp catalog_type(request, types) do
    with {:ok, suffix} <- family_or_error(request.gpu) do
      name = "gpu_#{request.gpu_count}x_#{suffix}"

      if Map.has_key?(types, name),
        do: {:ok, name},
        else: validation("Lambda has no #{name}: it #{listed(types, suffix)}")
    end
  end

  defp listed(types, suffix) do
    case listed_counts(types, suffix) do
      [] -> "lists no #{suffix} type"
      counts -> "lists #{suffix} with #{Enum.join(counts, ", ")} GPUs"
    end
  end

  defp listed_counts(types, suffix) do
    pattern = ~r/\Agpu_(\d+)x_#{Regex.escape(suffix)}\z/

    types
    |> Map.keys()
    |> Enum.flat_map(fn listed ->
      case Regex.run(pattern, listed) do
        [_, count] -> [String.to_integer(count)]
        nil -> []
      end
    end)
    |> Enum.sort()
  end

  defp listed_type(name, types) do
    if Map.has_key?(types, name),
      do: {:ok, name},
      else: validation("Lambda lists no instance type #{inspect(name)}")
  end

  defp family_or_error(gpu) do
    case family(gpu) do
      {:ok, suffix} ->
        {:ok, suffix}

      :error ->
        validation(
          "Lambda has no mapping for GPU #{inspect(gpu)}. Known: " <>
            inspect(Enum.sort(Spec.GpuCatalog.supported_gpus(:lambda_labs)))
        )
    end
  end

  defp family(canonical) do
    case Spec.GpuCatalog.for_provider(canonical, :lambda_labs) do
      {:ok, "gpu_1x_" <> suffix} -> {:ok, suffix}
      _ -> :error
    end
  end

  defp canonical_for("gpu_" <> rest) do
    case String.split(rest, "x_", parts: 2) do
      [_count, suffix] ->
        Enum.find(Spec.GpuCatalog.supported_gpus(:lambda_labs), &(family(&1) == {:ok, suffix}))

      _ ->
        nil
    end
  end

  defp canonical_for(_name), do: nil

  defp provider_opt(request, key),
    do: Map.get(request.provider_opts, key) || Map.get(request.provider_opts, to_string(key))

  # --- reading an instance ---

  defp status("booting"), do: :provisioning
  defp status("active"), do: :running
  # `:failed` would end a tracked session and delete the instance on a status
  # that can clear.
  defp status("unhealthy"), do: :running
  defp status("terminating"), do: :terminated
  defp status("terminated"), do: :terminated
  defp status("preempted"), do: :terminated
  # An unclassifiable instance is not a dead one: `UpstreamStatus` counts
  # `:provisioning` as alive.
  defp status(_), do: :provisioning

  defp tag_map(tags) when is_list(tags) do
    for %{"key" => key, "value" => value} when is_binary(key) and is_binary(value) <- tags,
        into: %{},
        do: {key, value}
  end

  defp tag_map(_tags), do: %{}

  defp parse_ports(nil), do: []

  defp parse_ports(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn spec ->
      with [port_str, protocol] <- String.split(spec, "/", parts: 2),
           {port, ""} <- Integer.parse(port_str),
           {:ok, protocol} <- protocol(protocol) do
        [{port, protocol}]
      else
        _ -> []
      end
    end)
  end

  defp protocol("http"), do: {:ok, :http}
  defp protocol("tcp"), do: {:ok, :tcp}
  defp protocol(_), do: :error

  defp binding({port, protocol}, ip),
    do: %{internal: port, external: port, protocol: protocol, url: port_url(protocol, ip, port)}

  defp port_url(_protocol, nil, _port), do: nil
  defp port_url(:http, ip, port), do: "http://#{ip}:#{port}"
  defp port_url(:tcp, ip, port), do: "tcp://#{ip}:#{port}"

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  # Anyone on the Lambda account can edit a tag. One far in the future would
  # keep an orphan inside the Reaper's grace window for ever, so it reads as
  # absent, which gets no grace. Clamping it to now would not help: every
  # read would see a new instance. A launching node's clock may run ahead of
  # this one, hence the allowance.
  defp drop_far_future(%DateTime{} = at) do
    limit = DateTime.add(DateTime.utc_now(), @max_clock_skew_s, :second)
    if DateTime.compare(at, limit) == :gt, do: nil, else: at
  end

  defp drop_far_future(nil), do: nil

  defp gpu_count(type) do
    case map_or_empty(type["specs"])["gpus"] do
      count when is_integer(count) and count > 0 -> count
      _ -> 1
    end
  end

  defp price(cents) when is_integer(cents), do: cents / 100
  defp price(_cents), do: nil

  # --- catalog ---

  defp gpu_type(name, entry) do
    type = map_or_empty(entry["instance_type"])
    regions = List.wrap(entry["regions_with_capacity_available"])

    %Spec.GpuType{
      id: name,
      provider: :lambda_labs,
      canonical: canonical_for(name),
      display_name: string_or_nil(type["description"]),
      memory_gb: memory_gb(type["gpu_description"]),
      lowest_price_per_hour: price(type["price_cents_per_hour"]),
      stock: if(regions == [], do: :unavailable, else: :unknown),
      raw: entry
    }
  end

  # "H100 (80 GB SXM5)" holds 80 GB per GPU.
  defp memory_gb(description) when is_binary(description) do
    case Regex.run(~r/(\d+)\s*GB/i, description) do
      [_, gb] -> String.to_integer(gb)
      nil -> nil
    end
  end

  defp memory_gb(_description), do: nil

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_), do: %{}

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp validation(message),
    do: {:error, Error.new(:validation, provider: :lambda_labs, message: message)}
end
