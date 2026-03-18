defmodule Atlas.Monitoring.HealthCheckTest do
  use Atlas.DataCase, async: true

  alias Atlas.Monitoring.HealthCheck

  setup do
    {:ok, credential} =
      Atlas.Providers.Credential.create(%{
        provider_type: :fly,
        name: "Test",
        api_token: "token"
      })

    {:ok, app} =
      Atlas.Infrastructure.App.create(%{
        provider_id: "app1",
        name: "test-app",
        provider_type: :fly,
        credential_id: credential.id
      })

    {:ok, machine} =
      Atlas.Infrastructure.Machine.create(%{
        provider_id: "m1",
        name: "worker",
        status: :started,
        app_id: app.id,
        credential_id: credential.id
      })

    %{credential: credential, machine: machine}
  end

  test "creates a health check", %{credential: credential, machine: machine} do
    assert {:ok, hc} =
             HealthCheck.create(%{
               status: :healthy,
               response_time_ms: 42,
               details: %{"checks" => []},
               machine_id: machine.id,
               credential_id: credential.id
             })

    assert hc.status == :healthy
    assert hc.response_time_ms == 42
  end

  test "lists recent checks for a machine", %{credential: credential, machine: machine} do
    for i <- 1..3 do
      HealthCheck.create(%{
        status: :healthy,
        response_time_ms: i * 10,
        machine_id: machine.id,
        credential_id: credential.id
      })
    end

    {:ok, checks} = HealthCheck.recent(machine.id)
    assert length(checks) == 3
  end
end
