defmodule ExAtlas.Providers.Vast.Translate do
  @moduledoc """
  Translation between ExAtlas specs and Vast.ai API bodies: the offer search,
  the pick among its offers, the rent body, and an instance as a `Compute`.

  Vast runs the image as a Docker container on a host it rents out whole.
  The rent body's `env` is a JSON object: each variable by name, and one
  `"-p 8000:8000" => "1"` entry per port, which Vast reads as a Docker flag.
  `ATLAS_PORTS` (`8000/http,22/tcp`) records each port's protocol, so a later
  read can build the port URLs; Vast's own `ports` map holds TCP numbers only.

  Every function here is pure, except `launch_parts/1`, which mints the
  `:auth` credential.
  """

  alias ExAtlas.{Error, Secret, Spec}

  @default_disk_gb 20
  @ports_var "ATLAS_PORTS"

  # The A100 40 GB and 80 GB share Vast's names; `gpu_ram` (MB) splits them.
  @gpu_ram_mb %{a100_80g: {"gte", 70_000}, a100_40g: {"lt", 70_000}}

  # How many matching offers one spawn tries to rent, cheapest first.
  @max_offers 3

  # The largest offer page Vast returns.
  @search_limit 64

  # The instance fields `raw` keeps: none holds an env value or a credential.
  @raw_keys ~w(id actual_status intended_status cur_state next_state label image_uuid
               image_runtype public_ipaddr ports gpu_name num_gpus gpu_ram gpu_totalram
               dph_total dph_base geolocation start_date end_date machine_id host_id
               ssh_host ssh_port disk_space is_bid)

  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @typedoc """
  What a rent needs from the request alone: the `env` object, its values as
  `ExAtlas.Secret`s, and the `Compute.auth` handle as a `Secret`, since its
  token is a credential and `parts` is an argument a crash would print.
  """
  @type parts :: %{env: %{String.t() => Secret.t()}, auth: Secret.t() | nil}

  @doc """
  Validate `request` and build its `env` object.

  Returns `{:error, %ExAtlas.Error{kind: :validation}}`, naming no value, for
  no `:image`; an `:image` or `:name` that is not UTF-8; an env name that is
  not `[A-Za-z_][A-Za-z0-9_]*`, which Vast would read as a Docker flag; a
  value holding a NUL byte or not UTF-8; an `ATLAS_PORTS` in `:env`; and a
  port that is not `{1..65535, :http | :tcp}`.
  """
  @spec launch_parts(Spec.ComputeRequest.t()) :: {:ok, parts()} | {:error, Error.t()}
  def launch_parts(%Spec.ComputeRequest{} = request) do
    with :ok <- check_image(request.image),
         :ok <- check_name(request.name),
         :ok <- check_reserved(request.env),
         {:ok, ports} <- ports(request.ports) do
      {auth_env, auth} = ExAtlas.Auth.for_scheme(request.auth)
      env = request |> Spec.ComputeRequest.container_env() |> Map.merge(auth_env)

      with :ok <- check_env(env) do
        {:ok, %{env: env_object(env, ports), auth: Secret.wrap(auth)}}
      end
    end
  end

  @doc """
  The `POST /api/v0/bundles/` body: on-demand, verified, rentable and
  unrented offers of the request's GPU, count, disk and ports, cheapest
  first. `datacenter` only for `cloud_type: :secure`.
  """
  @spec offer_query(Spec.ComputeRequest.t()) :: {:ok, map()} | {:error, Error.t()}
  def offer_query(%Spec.ComputeRequest{} = request) do
    with {:ok, query} <- gpu_query(request.gpu) do
      disk = disk_gb(request)

      {:ok,
       query
       |> Map.merge(%{
         "num_gpus" => %{"eq" => request.gpu_count},
         "disk_space" => %{"gte" => disk},
         "allocated_storage" => disk
       })
       |> Map.merge(port_filter(request.ports))
       |> Map.merge(cloud_filter(request.cloud_type))
       |> Map.merge(base_query())}
    end
  end

  @doc """
  The offer search body that finds the cheapest offers of `canonical`, for
  `list_gpu_types/1`.
  """
  @spec gpu_type_query(atom()) :: {:ok, map()} | {:error, Error.t()}
  def gpu_type_query(canonical) do
    with {:ok, query} <- gpu_query(canonical), do: {:ok, Map.merge(query, base_query())}
  end

  defp base_query do
    %{
      "verified" => %{"eq" => true},
      "rentable" => %{"eq" => true},
      "rented" => %{"eq" => false},
      "type" => "ondemand",
      "order" => [["dph_total", "asc"]],
      "limit" => @search_limit
    }
  end

  @doc """
  The offers to try, cheapest first, at most #{@max_offers}: those whose
  `geolocation` country code is the first of `hints` that any offer has,
  else the cheapest anywhere.
  """
  @spec pick([map()], [String.t()]) :: [map()]
  def pick(offers, hints) do
    offers =
      offers
      |> Enum.filter(&(is_map(&1) and is_integer(&1["id"])))
      |> Enum.sort_by(&price_key(&1["dph_total"]))

    in_hint =
      Enum.find_value(hints, fn hint ->
        case Enum.filter(offers, &(country(&1["geolocation"]) == String.upcase(hint))) do
          [] -> nil
          matching -> matching
        end
      end)

    Enum.take(in_hint || offers, @max_offers)
  end

  @doc """
  The `PUT /api/v0/asks/{id}/` body. `env` values stay `ExAtlas.Secret`s
  until `Vast.Client.put/4` encodes them.

  `runtype: "args"` with no `args` runs the image's own entrypoint; `ssh`
  would replace it with Vast's SSH setup. `cancel_unavail: true` makes Vast
  refuse an offer it cannot start now, rather than create a stopped instance
  that bills its disk.
  """
  @spec launch_body(Spec.ComputeRequest.t(), parts()) :: map()
  def launch_body(%Spec.ComputeRequest{} = request, parts) do
    %{
      "image" => request.image,
      "label" => request.name,
      "disk" => disk_gb(request),
      "runtype" => "args",
      "env" => parts.env,
      "cancel_unavail" => true
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  The `Compute` a rent returns, built from the request and the offer. No
  `GET` follows the rent: a failed read there must not turn a rented
  instance into an error the caller drops. `offer` is `nil` for a
  `provider_opts.offer_id` rent, which searched nothing.
  """
  @spec launched_compute(String.t(), Spec.ComputeRequest.t(), parts(), map() | nil) ::
          Spec.Compute.t()
  def launched_compute(id, request, parts, offer) do
    offer = offer || %{}

    %Spec.Compute{
      id: id,
      provider: :vast,
      status: :provisioning,
      ports:
        Enum.map(request.ports, fn {port, protocol} -> binding(port, protocol, nil, nil) end),
      gpu_type: string_or_nil(offer["gpu_name"]),
      gpu_count: count(offer["num_gpus"]) || request.gpu_count,
      cost_per_hour: number_or_nil(offer["dph_total"]),
      region: string_or_nil(offer["geolocation"]),
      image: request.image,
      name: request.name,
      auth: Secret.reveal(parts.auth),
      created_at: nil,
      raw: %{"new_contract" => id}
    }
  end

  @doc """
  Turn a Vast instance into an `ExAtlas.Spec.Compute`.

  `raw` keeps only the fields in `#{inspect(@raw_keys)}`. Vast's body also
  echoes the env values (`extra_env`, `onstart`), the container's arguments
  and the Jupyter token, and `list_compute/1` reads instances ExAtlas did not
  start, so a field Vast adds later stays out too.
  """
  @spec instance_to_compute(map()) :: Spec.Compute.t()
  def instance_to_compute(%{} = instance) do
    ip = instance["public_ipaddr"] |> string_or_nil() |> trim()

    %Spec.Compute{
      id: to_string(instance["id"]),
      provider: :vast,
      status: status(instance["actual_status"]),
      public_ip: ip,
      ports: instance_ports(instance, ip),
      gpu_type: string_or_nil(instance["gpu_name"]),
      gpu_count: count(instance["num_gpus"]) || 1,
      cost_per_hour: number_or_nil(instance["dph_total"]),
      region: string_or_nil(instance["geolocation"]),
      image: string_or_nil(instance["image_uuid"]),
      name: string_or_nil(instance["label"]),
      created_at: started_at(instance["start_date"]),
      raw: Map.take(instance, @raw_keys)
    }
  end

  @doc """
  Turn offers into `ExAtlas.Spec.GpuType`s: one per Vast GPU name, or per
  name and memory class where the catalog splits a name by `gpu_ram` (the
  A100), each at its lowest on-demand price.
  """
  @spec gpu_types([{atom(), [map()]}]) :: [Spec.GpuType.t()]
  def gpu_types(offers_by_gpu) do
    offers_by_gpu
    |> Enum.flat_map(fn {canonical, offers} ->
      offers
      |> Enum.filter(&(is_map(&1) and is_binary(&1["gpu_name"])))
      |> Enum.map(&{canonical, &1})
    end)
    |> Enum.group_by(fn {canonical, offer} -> {offer["gpu_name"], canonical} end)
    |> Enum.map(fn {{name, canonical}, entries} ->
      cheapest = entries |> Enum.map(&elem(&1, 1)) |> Enum.min_by(&price_key(&1["dph_total"]))

      %Spec.GpuType{
        id: name,
        provider: :vast,
        canonical: canonical,
        display_name: name,
        memory_gb: memory_gb(cheapest["gpu_ram"]),
        lowest_price_per_hour: number_or_nil(cheapest["dph_total"]),
        stock: :unknown,
        cloud_type: :any,
        raw: %{"gpu_name" => name, "dph_total" => cheapest["dph_total"]}
      }
    end)
    |> Enum.sort_by(&{&1.id, &1.memory_gb})
  end

  @doc "Whether `gpu_type` is one of `canonical`'s Vast names."
  @spec gpu_family?(String.t() | nil, atom()) :: boolean()
  def gpu_family?(gpu_type, canonical) when is_binary(gpu_type) do
    case Spec.GpuCatalog.for_provider(canonical, :vast) do
      {:ok, names} -> gpu_type in names
      _ -> false
    end
  end

  def gpu_family?(_gpu_type, _canonical), do: false

  # --- request checks ---

  defp check_image(image) when is_binary(image) do
    if String.valid?(image) and not String.contains?(image, <<0>>),
      do: :ok,
      else: validation(":image holds a NUL byte or is not valid UTF-8")
  end

  defp check_image(_image),
    do: validation("Vast runs a container, so it needs an :image")

  defp check_name(nil), do: :ok

  defp check_name(name) do
    if String.valid?(name), do: :ok, else: validation(":name is not valid UTF-8")
  end

  defp check_reserved(env) do
    if Map.has_key?(env, @ports_var),
      do: validation("#{@ports_var} is set by ExAtlas from :ports; remove it from :env"),
      else: :ok
  end

  # A name in Vast's `env` object that starts with `-` is a Docker flag
  # (`-p`, `-v`, `-h`), so only a plain identifier passes. The message names
  # the variable, never the value.
  defp check_env(env) do
    Enum.find_value(env, :ok, fn {name, value} ->
      cond do
        not Regex.match?(@env_name, name) ->
          validation(
            "env name #{inspect(name)} is not [A-Za-z_][A-Za-z0-9_]*; Vast reads other " <>
              "names as Docker flags"
          )

        not String.valid?(value) ->
          validation("the value of #{inspect(name)} is not valid UTF-8")

        String.contains?(value, <<0>>) ->
          validation("the value of #{inspect(name)} holds a NUL byte")

        true ->
          nil
      end
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
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
      error -> error
    end
  end

  defp env_object(env, []), do: Map.new(env, fn {name, value} -> {name, Secret.wrap(value)} end)

  defp env_object(env, ports) do
    flags = Map.new(ports, fn {port, _protocol} -> {"-p #{port}:#{port}", "1"} end)
    recorded = Enum.map_join(ports, ",", fn {port, protocol} -> "#{port}/#{protocol}" end)

    env
    |> Map.new(fn {name, value} -> {name, Secret.wrap(value)} end)
    |> Map.put(@ports_var, recorded)
    |> Map.merge(flags)
  end

  # --- offer search ---

  defp gpu_query(canonical) do
    case Spec.GpuCatalog.for_provider(canonical, :vast) do
      {:ok, names} ->
        query = %{"gpu_name" => %{"in" => names}}

        case @gpu_ram_mb[canonical] do
          nil -> {:ok, query}
          {op, mb} -> {:ok, Map.put(query, "gpu_ram", %{op => mb})}
        end

      {:error, _} ->
        validation(
          "Vast has no mapping for GPU #{inspect(canonical)}. Known: " <>
            inspect(Enum.sort(Spec.GpuCatalog.supported_gpus(:vast)))
        )
    end
  end

  defp port_filter([]), do: %{}

  defp port_filter(ports) do
    count = ports |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length()
    %{"direct_port_count" => %{"gte" => count}}
  end

  defp cloud_filter(:secure), do: %{"datacenter" => %{"eq" => true}}
  defp cloud_filter(_), do: %{}

  defp disk_gb(%Spec.ComputeRequest{container_disk_gb: nil}), do: @default_disk_gb
  defp disk_gb(%Spec.ComputeRequest{container_disk_gb: gb}), do: gb

  # "Texas, US" is in US. A geolocation with no comma names no country.
  defp country(geolocation) when is_binary(geolocation) do
    case String.split(geolocation, ", ") do
      [_only] -> nil
      parts -> parts |> List.last() |> String.trim() |> String.upcase()
    end
  end

  defp country(_), do: nil

  # An offer with no price sorts last.
  defp price_key(price) when is_number(price), do: {0, price}
  defp price_key(_price), do: {1, 0}

  # --- reading an instance ---

  # Vast's docs: `exited`, `offline` and `unknown` never reach `running`.
  # `exited` still bills its disk, so it reads `:stopped`, not gone.
  defp status("running"), do: :running
  defp status("exited"), do: :stopped
  defp status("offline"), do: :failed
  defp status("unknown"), do: :failed
  # `UpstreamStatus` counts `:provisioning` as alive.
  defp status(_), do: :provisioning

  # Vast's `ports` is Docker's map, `"8000/tcp" => [%{"HostPort" => "41234"}]`.
  # The protocol comes from `ATLAS_PORTS` in `extra_env`; a port ExAtlas did
  # not record reads `:tcp`.
  defp instance_ports(instance, ip) do
    mapped = host_ports(instance["ports"])
    recorded = recorded_ports(instance["extra_env"])

    if recorded == [] do
      mapped
      |> Enum.sort()
      |> Enum.map(fn {internal, external} -> binding(internal, :tcp, external, ip) end)
    else
      Enum.map(recorded, fn {port, protocol} ->
        binding(port, protocol, Map.get(mapped, port), ip)
      end)
    end
  end

  defp host_ports(%{} = ports) do
    for {key, [%{"HostPort" => host} | _]} <- ports,
        [port_str, "tcp"] <- [String.split(to_string(key), "/", parts: 2)],
        {port, ""} <- [Integer.parse(port_str)],
        {external, ""} <- [Integer.parse(to_string(host))],
        into: %{},
        do: {port, external}
  end

  defp host_ports(_ports), do: %{}

  defp recorded_ports(extra_env) do
    case env_value(extra_env, @ports_var) do
      value when is_binary(value) -> parse_ports(value)
      _ -> []
    end
  end

  # `extra_env` is a list of `[name, value]` pairs.
  defp env_value(pairs, name) when is_list(pairs) do
    Enum.find_value(pairs, fn
      [^name, value | _] -> value
      _ -> nil
    end)
  end

  defp env_value(%{} = env, name), do: env[name]
  defp env_value(_env, _name), do: nil

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

  defp binding(port, protocol, external, ip),
    do: %{
      internal: port,
      external: external,
      protocol: protocol,
      url: port_url(protocol, ip, external)
    }

  defp port_url(_protocol, nil, _port), do: nil
  defp port_url(_protocol, _ip, nil), do: nil
  defp port_url(:http, ip, port), do: "http://#{ip}:#{port}"
  defp port_url(:tcp, ip, port), do: "tcp://#{ip}:#{port}"

  defp started_at(epoch) when is_number(epoch) and epoch > 0 do
    case DateTime.from_unix(trunc(epoch)) do
      {:ok, at} -> at
      _ -> nil
    end
  end

  defp started_at(_epoch), do: nil

  # "A100 SXM4" offers 81920 MB.
  defp memory_gb(mb) when is_number(mb) and mb > 0, do: round(mb / 1024)
  defp memory_gb(_mb), do: nil

  defp count(n) when is_integer(n) and n > 0, do: n
  defp count(_n), do: nil

  defp number_or_nil(n) when is_number(n), do: n
  defp number_or_nil(_n), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp trim(nil), do: nil

  defp trim(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validation(message),
    do: {:error, Error.new(:validation, provider: :vast, message: message)}
end
