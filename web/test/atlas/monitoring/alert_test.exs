defmodule Atlas.Monitoring.AlertTest do
  use Atlas.DataCase, async: true

  alias Atlas.Monitoring.Alert

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

  test "creates an alert", %{credential: credential, machine: machine} do
    assert {:ok, alert} =
             Alert.create(%{
               severity: :critical,
               title: "Machine unhealthy",
               message: "Health check failed",
               machine_id: machine.id,
               credential_id: credential.id
             })

    assert alert.severity == :critical
    assert alert.status == :firing
  end

  test "acknowledges an alert", %{credential: credential, machine: machine} do
    {:ok, alert} =
      Alert.create(%{
        severity: :warning,
        title: "Test alert",
        credential_id: credential.id,
        machine_id: machine.id
      })

    {:ok, acked} = Alert.acknowledge(alert)
    assert acked.status == :acknowledged
    assert acked.acknowledged_at != nil
  end

  test "resolves an alert", %{credential: credential, machine: machine} do
    {:ok, alert} =
      Alert.create(%{
        severity: :warning,
        title: "Test alert",
        credential_id: credential.id,
        machine_id: machine.id
      })

    {:ok, resolved} = Alert.resolve(alert)
    assert resolved.status == :resolved
    assert resolved.resolved_at != nil
  end

  test "lists active alerts", %{credential: credential, machine: machine} do
    {:ok, _firing} =
      Alert.create(%{
        severity: :critical,
        title: "Firing alert",
        credential_id: credential.id,
        machine_id: machine.id
      })

    {:ok, resolved_alert} =
      Alert.create(%{
        severity: :info,
        title: "Resolved alert",
        credential_id: credential.id,
        machine_id: machine.id
      })

    Alert.resolve(resolved_alert)

    {:ok, active} = Alert.list_active()
    assert length(active) == 1
    assert hd(active).title == "Firing alert"
  end
end
