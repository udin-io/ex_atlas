defmodule Atlas.Monitoring.Workers.HealthCheckCronWorker do
  @moduledoc """
  Cron worker that enqueues health check jobs for each active credential.
  Runs every 5 minutes.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    case Atlas.Providers.Credential.list_sync_enabled() do
      {:ok, credentials} ->
        Enum.each(credentials, fn credential ->
          %{credential_id: credential.id}
          |> Atlas.Monitoring.Workers.HealthCheckWorker.new()
          |> Oban.insert()
        end)

        :ok

      {:error, _} ->
        :ok
    end
  end
end
