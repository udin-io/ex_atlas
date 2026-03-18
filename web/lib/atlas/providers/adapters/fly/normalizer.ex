defmodule Atlas.Providers.Adapters.Fly.Normalizer do
  @moduledoc """
  Transforms Fly.io API responses into canonical maps
  matching Atlas Ash resource attributes.
  """

  def normalize_app(app_data, _credential) do
    status =
      case app_data["status"] do
        "deployed" -> :deployed
        "suspended" -> :suspended
        "pending" -> :pending
        "error" -> :error
        "destroyed" -> :destroyed
        _ -> :pending
      end

    %{
      provider_id: app_data["id"],
      name: app_data["name"],
      region: nil,
      metadata: %{
        "machine_count" => app_data["machine_count"],
        "network" => app_data["network"]
      },
      provider_type: :fly,
      status: status
    }
  end

  def normalize_machine(machine_data, _credential) do
    config = machine_data["config"] || %{}
    guest = config["guest"] || %{}
    image_ref = machine_data["image_ref"] || %{}

    ip_addresses =
      case machine_data["private_ip"] do
        nil -> []
        ip -> [ip]
      end

    status =
      case machine_data["state"] do
        "created" -> :created
        "started" -> :started
        "stopped" -> :stopped
        "suspended" -> :suspended
        "destroyed" -> :destroyed
        "replacing" -> :started
        "restarting" -> :started
        _ -> :created
      end

    %{
      provider_id: machine_data["id"],
      name: machine_data["name"],
      region: machine_data["region"],
      image: build_image_string(image_ref),
      ip_addresses: ip_addresses,
      cpu_kind: guest["cpu_kind"],
      cpus: guest["cpus"],
      memory_mb: guest["memory_mb"],
      gpu_type: guest["gpu_kind"],
      status: status
    }
  end

  def normalize_volume(volume_data, _credential) do
    %{
      provider_id: volume_data["id"],
      name: volume_data["name"],
      size_gb: volume_data["size_gb"],
      region: volume_data["region"],
      status: volume_data["state"] || "created"
    }
  end

  defp build_image_string(%{"repository" => repo, "tag" => tag}) when is_binary(repo) do
    if tag, do: "#{repo}:#{tag}", else: repo
  end

  defp build_image_string(_), do: nil
end
