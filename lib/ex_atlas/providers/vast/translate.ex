defmodule ExAtlas.Providers.Vast.Translate do
  @moduledoc """
  Translation between ExAtlas specs and Vast.ai API bodies: an instance as
  a `Compute`.

  Vast runs the image as a Docker container on a host it rents out whole.
  The rent body's `env` is a JSON object: each variable by name, and one
  `"-p 8000:8000" => "1"` entry per port, which Vast reads as a Docker flag.
  `ATLAS_PORTS` (`8000/http,22/tcp`) records each port's protocol, so a later
  read can build the port URLs; Vast's own `ports` map holds TCP numbers only.

  Every function here is pure.
  """

  alias ExAtlas.Spec

  @ports_var "ATLAS_PORTS"

  @doc """
  Turn a Vast instance into an `ExAtlas.Spec.Compute`.

  `raw` drops `extra_env` and `onstart`, which echo the env values, and
  `jupyter_token`.
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
      raw: Map.drop(instance, ["extra_env", "onstart", "jupyter_token"])
    }
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
end
