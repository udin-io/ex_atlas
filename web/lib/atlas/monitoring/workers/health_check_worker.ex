defmodule Atlas.Monitoring.Workers.HealthCheckWorker do
  @moduledoc """
  Oban worker that performs health checks on machines
  and creates alert records when thresholds are breached.
  """

  use Oban.Worker, queue: :default, max_attempts: 2

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"credential_id" => credential_id}}) do
    with {:ok, credential} <- Atlas.Providers.Credential.get_by_id(credential_id),
         {:ok, adapter} <- Atlas.Providers.Adapter.adapter_for(credential.provider_type) do
      if function_exported?(adapter, :health_check, 2) do
        check_machines(adapter, credential)
      else
        :ok
      end
    else
      {:error, reason} ->
        Logger.error(
          "Health check worker failed for credential #{credential_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp check_machines(adapter, credential) do
    case Atlas.Infrastructure.Machine.by_credential(credential.id) do
      {:ok, machines} ->
        machines
        |> Enum.filter(&(&1.status in [:started, :created]))
        |> Enum.each(&check_machine(adapter, credential, &1))

        :ok

      {:error, reason} ->
        Logger.warning("Failed to load machines for health check: #{inspect(reason)}")
        :ok
    end
  end

  defp check_machine(adapter, credential, machine) do
    start_time = System.monotonic_time(:millisecond)

    result = adapter.health_check(credential, machine.id)
    response_time = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, %{status: status}} ->
        Atlas.Monitoring.HealthCheck.create(%{
          machine_id: machine.id,
          credential_id: credential.id,
          status: status,
          response_time_ms: response_time,
          details: %{}
        })

        if status in [:unhealthy, :unreachable] do
          create_alert(credential, machine, status)
        end

      {:error, reason} ->
        Atlas.Monitoring.HealthCheck.create(%{
          machine_id: machine.id,
          credential_id: credential.id,
          status: :unreachable,
          response_time_ms: response_time,
          details: %{"error" => inspect(reason)}
        })

        create_alert(credential, machine, :unreachable)
    end
  end

  defp create_alert(credential, machine, status) do
    severity = if status == :unreachable, do: :critical, else: :warning
    machine_name = machine.name || machine.provider_id

    Atlas.Monitoring.Alert.create(%{
      severity: severity,
      title: "Machine #{machine_name} is #{status}",
      message: "Health check returned #{status} for machine #{machine_name}",
      machine_id: machine.id,
      credential_id: credential.id
    })
  end
end
