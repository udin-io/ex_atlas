defmodule Atlas.Monitoring do
  use Ash.Domain, otp_app: :atlas, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Atlas.Monitoring.HealthCheck
    resource Atlas.Monitoring.MetricSnapshot
    resource Atlas.Monitoring.Alert
  end
end
