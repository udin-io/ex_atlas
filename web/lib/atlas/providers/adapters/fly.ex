defmodule Atlas.Providers.Adapters.Fly do
  @moduledoc """
  Fly.io provider adapter implementation.
  """

  @behaviour Atlas.Providers.Adapter

  alias Atlas.Providers.Adapters.Fly.{Client, Normalizer}

  @impl true
  def test_connection(credential) do
    org_slug = credential.org_slug || "personal"

    with {:ok, client} <- Client.new(credential) do
      case Client.list_apps(client, org_slug) do
        {:ok, %{status: 200}} -> :ok
        {:ok, %{status: 401}} -> {:error, "Invalid API token"}
        {:ok, %{status: 403}} -> {:error, "Access forbidden - check token permissions"}
        {:ok, %{status: status}} -> {:error, "Unexpected status: #{status}"}
        {:error, reason} -> {:error, "Connection failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_apps(credential) do
    org_slug = credential.org_slug || "personal"

    with {:ok, client} <- Client.new(credential) do
      case Client.list_apps(client, org_slug) do
        {:ok, %{status: 200, body: %{"apps" => apps}}} ->
          normalized = Enum.map(apps, &Normalizer.normalize_app(&1, credential))
          {:ok, normalized}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to list apps (#{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_machines(credential, app_name) do
    with {:ok, client} <- Client.new(credential) do
      case Client.list_machines(client, app_name) do
        {:ok, %{status: 200, body: machines}} when is_list(machines) ->
          normalized = Enum.map(machines, &Normalizer.normalize_machine(&1, credential))
          {:ok, normalized}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to list machines (#{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_volumes(credential, app_name) do
    with {:ok, client} <- Client.new(credential) do
      case Client.list_volumes(client, app_name) do
        {:ok, %{status: 200, body: volumes}} when is_list(volumes) ->
          normalized = Enum.map(volumes, &Normalizer.normalize_volume(&1, credential))
          {:ok, normalized}

        {:ok, %{status: status, body: body}} ->
          {:error, "Failed to list volumes (#{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, "Request failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def list_storage_buckets(_credential) do
    {:ok, []}
  end

  @impl true
  def health_check(credential, machine_id) do
    with {:ok, client} <- Client.new(credential) do
      # We need the app name to query the machine - find it from our DB
      case Atlas.Infrastructure.Machine.get_by_id(machine_id) do
        {:ok, machine} ->
          app = Ash.load!(machine, :app).app

          case Client.get_machine(client, app.name, machine.provider_id) do
            {:ok, %{status: 200, body: body}} ->
              checks = body["checks"] || []

              status =
                cond do
                  Enum.all?(checks, &(&1["status"] == "passing")) -> :healthy
                  Enum.any?(checks, &(&1["status"] == "critical")) -> :unhealthy
                  Enum.any?(checks, &(&1["status"] == "warning")) -> :degraded
                  true -> :healthy
                end

              {:ok, %{status: status, checks: checks, state: body["state"]}}

            {:ok, %{status: status}} ->
              {:error, "Health check failed with status #{status}"}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, _} ->
          {:error, "Machine not found"}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def start_machine(credential, app_name, machine_id) do
    with {:ok, client} <- Client.new(credential) do
      case Client.start_machine(client, app_name, machine_id) do
        {:ok, %{status: status}} when status in [200, 202] ->
          {:ok, %{status: :started}}

        {:ok, %{status: status, body: body}} ->
          {:error, "Start failed (#{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end

  @impl true
  def stop_machine(credential, app_name, machine_id) do
    with {:ok, client} <- Client.new(credential) do
      case Client.stop_machine(client, app_name, machine_id) do
        {:ok, %{status: status}} when status in [200, 202] ->
          {:ok, %{status: :stopped}}

        {:ok, %{status: status, body: body}} ->
          {:error, "Stop failed (#{status}): #{inspect(body)}"}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, "Failed to create client: #{inspect(reason)}"}
    end
  end
end
