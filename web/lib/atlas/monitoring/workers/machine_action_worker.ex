defmodule Atlas.Monitoring.Workers.MachineActionWorker do
  @moduledoc """
  Oban worker for executing machine management actions (start/stop).
  Uses Oban for retry semantics and persistence.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"action" => action, "machine_id" => machine_id}}) do
    with {:ok, machine} <- Atlas.Infrastructure.Machine.get_by_id(machine_id),
         {:ok, app} <- load_app(machine),
         {:ok, credential} <- Atlas.Providers.Credential.get_by_id(machine.credential_id),
         {:ok, adapter} <- Atlas.Providers.Adapter.adapter_for(credential.provider_type) do
      execute_action(action, adapter, credential, app, machine)
    else
      {:error, reason} ->
        Logger.error("Machine action #{action} failed for #{machine_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp execute_action("start", adapter, credential, app, machine) do
    if function_exported?(adapter, :start_machine, 3) do
      case adapter.start_machine(credential, app.name, machine.provider_id) do
        {:ok, _} ->
          Logger.info("Machine #{machine.provider_id} started successfully")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Provider #{credential.provider_type} does not support start_machine"}
    end
  end

  defp execute_action("stop", adapter, credential, app, machine) do
    if function_exported?(adapter, :stop_machine, 3) do
      case adapter.stop_machine(credential, app.name, machine.provider_id) do
        {:ok, _} ->
          Logger.info("Machine #{machine.provider_id} stopped successfully")
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Provider #{credential.provider_type} does not support stop_machine"}
    end
  end

  defp execute_action(action, _adapter, _credential, _app, _machine) do
    {:error, "Unknown action: #{action}"}
  end

  defp load_app(machine) do
    case Ash.load(machine, :app) do
      {:ok, %{app: app}} -> {:ok, app}
      error -> error
    end
  end

  @doc "Enqueue a start action for a machine."
  def enqueue_start(machine_id) do
    %{action: "start", machine_id: machine_id}
    |> new()
    |> Oban.insert()
  end

  @doc "Enqueue a stop action for a machine."
  def enqueue_stop(machine_id) do
    %{action: "stop", machine_id: machine_id}
    |> new()
    |> Oban.insert()
  end
end
