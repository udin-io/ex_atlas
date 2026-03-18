defmodule Atlas.Providers.SyncManager do
  @moduledoc """
  Manages sync workers for all active credentials.

  Starts on boot, queries credentials with sync_enabled, and
  starts a SyncWorker per credential via DynamicSupervisor.
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_sync(credential_id) do
    GenServer.call(__MODULE__, {:start_sync, credential_id})
  end

  def stop_sync(credential_id) do
    GenServer.call(__MODULE__, {:stop_sync, credential_id})
  end

  def restart_sync(credential_id) do
    GenServer.call(__MODULE__, {:restart_sync, credential_id})
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :start_workers, 1_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:start_workers, state) do
    case Atlas.Providers.Credential.list_sync_enabled() do
      {:ok, credentials} ->
        Enum.each(credentials, &start_worker/1)

      {:error, reason} ->
        Logger.error("Failed to load sync-enabled credentials: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call({:start_sync, credential_id}, _from, state) do
    case Atlas.Providers.Credential.get_by_id(credential_id) do
      {:ok, credential} ->
        result = start_worker(credential)
        {:reply, result, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop_sync, credential_id}, _from, state) do
    result = stop_worker(credential_id)
    {:reply, result, state}
  end

  def handle_call({:restart_sync, credential_id}, _from, state) do
    stop_worker(credential_id)

    case Atlas.Providers.Credential.get_by_id(credential_id) do
      {:ok, credential} ->
        result = start_worker(credential)
        {:reply, result, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp start_worker(credential) do
    case Registry.lookup(Atlas.Providers.SyncRegistry, credential.id) do
      [{_pid, _}] ->
        {:ok, :already_running}

      [] ->
        DynamicSupervisor.start_child(
          Atlas.Providers.SyncSupervisor,
          {Atlas.Providers.SyncWorker, credential: credential}
        )
    end
  end

  defp stop_worker(credential_id) do
    case Registry.lookup(Atlas.Providers.SyncRegistry, credential_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Atlas.Providers.SyncSupervisor, pid)

      [] ->
        {:ok, :not_running}
    end
  end
end
