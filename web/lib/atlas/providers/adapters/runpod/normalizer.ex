defmodule Atlas.Providers.Adapters.RunPod.Normalizer do
  @moduledoc """
  Transforms RunPod API responses into canonical maps
  matching Atlas Ash resource attributes.
  """

  def normalize_pod_as_app(pod_data, _credential) do
    status =
      case pod_data["desiredStatus"] do
        "RUNNING" -> :deployed
        "EXITED" -> :suspended
        "TERMINATED" -> :destroyed
        "CREATED" -> :pending
        _ -> :pending
      end

    %{
      provider_id: pod_data["id"],
      name: pod_data["name"] || pod_data["id"],
      region: nil,
      metadata: %{
        "cost_per_hr" => pod_data["costPerHr"],
        "gpu_count" => pod_data["gpuCount"],
        "pod_type" => pod_data["podType"],
        "image" => pod_data["imageName"] || dig(pod_data, ["image", "imageName"])
      },
      provider_type: :runpod,
      status: status
    }
  end

  def normalize_pod_as_machine(pod_data, _credential) do
    gpu_info = pod_data["gpu"] || %{}
    gpu_display = gpu_info["displayName"] || pod_data["gpuDisplayName"]

    status =
      case pod_data["desiredStatus"] do
        "RUNNING" -> :started
        "EXITED" -> :stopped
        "TERMINATED" -> :destroyed
        "CREATED" -> :created
        _ -> :created
      end

    memory_mb =
      case pod_data["memoryInGb"] do
        nil -> nil
        gb when is_number(gb) -> round(gb * 1024)
      end

    %{
      provider_id: pod_data["id"],
      name: pod_data["name"] || pod_data["id"],
      region: nil,
      image: pod_data["imageName"] || dig(pod_data, ["image", "imageName"]),
      ip_addresses: extract_ips(pod_data),
      cpu_kind: pod_data["cpuFlavorId"],
      cpus: pod_data["vcpuCount"],
      memory_mb: memory_mb,
      gpu_type: gpu_display,
      status: status
    }
  end

  def normalize_network_volume(volume_data, _credential) do
    size_gb = volume_data["size"] || volume_data["sizeInGb"]

    %{
      provider_id: volume_data["id"],
      name: volume_data["name"] || volume_data["id"],
      size_bytes: if(size_gb, do: size_gb * 1_073_741_824, else: nil),
      object_count: nil,
      region: volume_data["dataCenterId"]
    }
  end

  defp extract_ips(pod_data) do
    case dig(pod_data, ["runtime", "ports"]) do
      ports when is_list(ports) ->
        ports
        |> Enum.map(& &1["ip"])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp dig(data, keys) when is_map(data) do
    Enum.reduce_while(keys, data, fn key, acc ->
      case acc do
        %{^key => val} -> {:cont, val}
        _ -> {:halt, nil}
      end
    end)
  end

  defp dig(_, _), do: nil
end
