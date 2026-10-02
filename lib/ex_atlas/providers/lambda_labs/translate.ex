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

  Every function here is pure.
  """

  alias ExAtlas.Spec

  @tag_ports "atlas-ports"
  @tag_created_at "atlas-created-at"
  @tag_image "atlas-image"
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
      created_at: parse_time(tags[@tag_created_at]),
      # `jupyter_token`, and the URL that carries it, open the instance's
      # Jupyter.
      raw: Map.drop(instance, ["jupyter_token", "jupyter_url"])
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

  defp family(canonical) do
    with {:ok, "gpu_1x_" <> suffix} <- Spec.GpuCatalog.for_provider(canonical, :lambda_labs) do
      {:ok, suffix}
    else
      _ -> :error
    end
  end

  defp canonical_for("gpu_" <> rest) do
    with [_count, suffix] <- String.split(rest, "x_", parts: 2) do
      Enum.find(Spec.GpuCatalog.supported_gpus(:lambda_labs), &(family(&1) == {:ok, suffix}))
    else
      _ -> nil
    end
  end

  defp canonical_for(_name), do: nil

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
end
