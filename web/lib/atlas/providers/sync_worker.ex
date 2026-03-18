defmodule Atlas.Providers.SyncWorker do
  @moduledoc """
  GenServer that periodically syncs infrastructure data
  from a single provider credential.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    credential = Keyword.fetch!(opts, :credential)

    GenServer.start_link(__MODULE__, credential, name: via_tuple(credential.id))
  end

  defp via_tuple(credential_id) do
    {:via, Registry, {Atlas.Providers.SyncRegistry, credential_id}}
  end

  @impl true
  def init(credential) do
    Logger.info("Starting sync worker for credential #{credential.id} (#{credential.name})")
    schedule_sync(0)
    {:ok, %{credential_id: credential.id, interval: credential.sync_interval_seconds * 1_000}}
  end

  @impl true
  def handle_info(:sync, state) do
    case Atlas.Providers.Credential.get_by_id(state.credential_id) do
      {:ok, credential} ->
        perform_sync(credential)
        schedule_sync(state.interval)
        {:noreply, state}

      {:error, _reason} ->
        Logger.warning("Credential #{state.credential_id} not found, stopping worker")
        {:stop, :normal, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp schedule_sync(delay) do
    Process.send_after(self(), :sync, delay)
  end

  defp perform_sync(credential) do
    Logger.info("Syncing credential #{credential.id} (#{credential.name})")

    with {:ok, adapter} <- Atlas.Providers.Adapter.adapter_for(credential.provider_type) do
      cycle_start = DateTime.utc_now()

      with {:ok, apps} <- sync_apps(adapter, credential),
           :ok <- sync_machines_and_volumes(adapter, credential, apps),
           :ok <- sync_storage_buckets(adapter, credential),
           :ok <- mark_stale_resources(credential, cycle_start) do
        Atlas.Providers.Credential.mark_synced(credential)
        Logger.info("Sync complete for credential #{credential.id}")
      else
        {:error, reason} ->
          Logger.error("Sync failed for credential #{credential.id}: #{inspect(reason)}")

          Atlas.Providers.Credential.mark_error(credential, %{
            message: "Sync failed: #{inspect(reason)}"
          })
      end
    else
      {:error, :unknown_provider} ->
        Logger.error("Unknown provider type: #{credential.provider_type}")
    end
  end

  defp sync_apps(adapter, credential) do
    case adapter.list_apps(credential) do
      {:ok, apps_data} ->
        results =
          Enum.map(apps_data, fn app_data ->
            Atlas.Infrastructure.App.upsert(Map.put(app_data, :credential_id, credential.id))
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if errors == [] do
          apps = Enum.map(results, fn {:ok, app} -> app end)
          {:ok, apps}
        else
          {:error, {:app_sync_errors, errors}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp sync_machines_and_volumes(adapter, credential, apps) do
    results =
      Enum.map(apps, fn app ->
        with :ok <- sync_machines(adapter, credential, app),
             :ok <- sync_volumes(adapter, credential, app) do
          :ok
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      :ok
    else
      Logger.warning("Some machine/volume syncs failed: #{inspect(errors)}")
      :ok
    end
  end

  defp sync_machines(adapter, credential, app) do
    # Fly uses app name in URLs, RunPod uses provider_id
    app_ref = if credential.provider_type == :runpod, do: app.provider_id, else: app.name

    case adapter.list_machines(credential, app_ref) do
      {:ok, machines_data} ->
        Enum.each(machines_data, fn machine_data ->
          Atlas.Infrastructure.Machine.upsert(
            machine_data
            |> Map.put(:app_id, app.id)
            |> Map.put(:credential_id, credential.id)
          )
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to sync machines for app #{app.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_volumes(adapter, credential, app) do
    app_ref = if credential.provider_type == :runpod, do: app.provider_id, else: app.name

    case adapter.list_volumes(credential, app_ref) do
      {:ok, volumes_data} ->
        Enum.each(volumes_data, fn volume_data ->
          Atlas.Infrastructure.Volume.upsert(
            volume_data
            |> Map.put(:app_id, app.id)
            |> Map.put(:credential_id, credential.id)
          )
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to sync volumes for app #{app.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp sync_storage_buckets(adapter, credential) do
    case adapter.list_storage_buckets(credential) do
      {:ok, buckets_data} ->
        Enum.each(buckets_data, fn bucket_data ->
          Atlas.Infrastructure.StorageBucket.upsert(
            Map.put(bucket_data, :credential_id, credential.id)
          )
        end)

        :ok

      {:error, reason} ->
        Logger.warning("Failed to sync storage buckets: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_stale_resources(credential, cycle_start) do
    # Mark apps that weren't updated in this cycle as destroyed
    case Atlas.Infrastructure.App.by_credential(credential.id) do
      {:ok, apps} ->
        Enum.each(apps, fn app ->
          if app.synced_at && DateTime.compare(app.synced_at, cycle_start) == :lt &&
               app.status != :destroyed do
            Atlas.Infrastructure.App.mark_destroyed(app)
          end
        end)

      _ ->
        :ok
    end

    :ok
  end
end
