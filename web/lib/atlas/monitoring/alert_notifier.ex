defmodule Atlas.Monitoring.AlertNotifier do
  @moduledoc """
  Sends email notifications for critical alerts via Swoosh.
  """

  import Swoosh.Email

  alias Atlas.Mailer

  def notify_alert(alert) do
    if alert.severity == :critical do
      send_alert_email(alert)
    end
  end

  defp send_alert_email(alert) do
    email =
      new()
      |> to(admin_email())
      |> from({"Atlas Alerts", "alerts@atlas.local"})
      |> subject("[#{String.upcase(to_string(alert.severity))}] #{alert.title}")
      |> text_body("""
      Atlas Alert: #{alert.title}

      Severity: #{alert.severity}
      Status: #{alert.status}
      Message: #{alert.message || "N/A"}

      #{if alert.metric_name, do: "Metric: #{alert.metric_name}", else: ""}
      #{if alert.threshold_value, do: "Threshold: #{alert.threshold_value}", else: ""}
      #{if alert.actual_value, do: "Actual: #{alert.actual_value}", else: ""}

      Time: #{Calendar.strftime(alert.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}

      View in Atlas: /dashboard
      """)

    Mailer.deliver(email)
  end

  defp admin_email do
    Application.get_env(:atlas, :alert_email, "admin@dev.local")
  end
end
