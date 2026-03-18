defmodule AtlasWeb.DashboardLive do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents
  import AtlasWeb.MetricComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    credentials = load_credentials()

    if connected?(socket) do
      Enum.each(credentials, fn cred ->
        Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:credential:#{cred.id}")
      end)

      Phoenix.PubSub.subscribe(Atlas.PubSub, "providers:credentials")
      Phoenix.PubSub.subscribe(Atlas.PubSub, "monitoring:alerts")
    end

    apps = load_apps()
    machines = load_machines()
    alerts = load_active_alerts()

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       credentials: credentials,
       apps: apps,
       machines: machines,
       alerts: alerts,
       total_apps: length(apps),
       total_machines: length(machines),
       running_machines: Enum.count(machines, &(&1.status == :started)),
       provider_count: length(credentials),
       active_alerts: length(alerts)
     )}
  end

  @impl true
  def handle_info(%{topic: "infrastructure:credential:" <> _}, socket) do
    apps = load_apps()
    machines = load_machines()

    {:noreply,
     assign(socket,
       apps: apps,
       machines: machines,
       total_apps: length(apps),
       total_machines: length(machines),
       running_machines: Enum.count(machines, &(&1.status == :started))
     )}
  end

  def handle_info(%{topic: "providers:credentials"}, socket) do
    credentials = load_credentials()

    {:noreply,
     assign(socket,
       credentials: credentials,
       provider_count: length(credentials)
     )}
  end

  def handle_info(%{topic: "monitoring:alerts"}, socket) do
    alerts = load_active_alerts()
    {:noreply, assign(socket, alerts: alerts, active_alerts: length(alerts))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("acknowledge_alert", %{"id" => alert_id}, socket) do
    case Atlas.Monitoring.Alert.get_by_id(alert_id) do
      {:ok, alert} ->
        Atlas.Monitoring.Alert.acknowledge(alert)
        alerts = load_active_alerts()
        {:noreply, assign(socket, alerts: alerts, active_alerts: length(alerts))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Dashboard
        <:subtitle>Infrastructure overview</:subtitle>
      </.header>

      <div class="stats shadow w-full bg-base-100">
        <.stat_card label="Providers" value={@provider_count} />
        <.stat_card label="Apps" value={@total_apps} />
        <.stat_card label="Machines" value={@total_machines} />
        <.stat_card
          label="Running"
          value={@running_machines}
          description={"of #{@total_machines} machines"}
        />
        <.stat_card
          label="Alerts"
          value={@active_alerts}
          class={@active_alerts > 0 && "text-error"}
        />
      </div>

      <div :if={@alerts != []} class="card bg-base-100 shadow-sm border border-error/30">
        <div class="card-body">
          <h2 class="card-title text-base text-error">
            <.icon name="hero-exclamation-triangle" class="size-5" /> Active Alerts ({@active_alerts})
          </h2>
          <div
            :for={alert <- Enum.take(@alerts, 5)}
            class="flex items-center justify-between py-2 border-b border-base-200 last:border-0"
          >
            <div class="flex items-center gap-2">
              <span class={[
                "badge badge-sm",
                alert.severity == :critical && "badge-error",
                alert.severity == :warning && "badge-warning",
                alert.severity == :info && "badge-info"
              ]}>
                {alert.severity}
              </span>
              <span class="text-sm">{alert.title}</span>
            </div>
            <button
              :if={alert.status == :firing}
              phx-click="acknowledge_alert"
              phx-value-id={alert.id}
              class="btn btn-ghost btn-xs"
            >
              Acknowledge
            </button>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body">
            <h2 class="card-title text-base">Providers</h2>
            <div :if={@credentials == []} class="text-sm text-base-content/60 py-4">
              No providers configured.
              <.link navigate={~p"/providers/new"} class="link link-primary">
                Add one
              </.link>
            </div>
            <div
              :for={cred <- @credentials}
              class="flex items-center justify-between py-2 border-b border-base-200 last:border-0"
            >
              <div class="flex items-center gap-2">
                <.provider_icon provider_type={cred.provider_type} class="size-4" />
                <.link
                  navigate={~p"/providers/#{cred.id}"}
                  class="link link-hover font-medium text-sm"
                >
                  {cred.name}
                </.link>
              </div>
              <.sync_status credential={cred} />
            </div>
          </div>
        </div>

        <div class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <h2 class="card-title text-base">Recent Apps</h2>
              <.link navigate={~p"/infrastructure"} class="btn btn-ghost btn-xs">
                View all
              </.link>
            </div>
            <div :if={@apps == []} class="text-sm text-base-content/60 py-4">
              No apps discovered yet.
            </div>
            <div
              :for={app <- Enum.take(@apps, 5)}
              class="flex items-center justify-between py-2 border-b border-base-200 last:border-0"
            >
              <div class="flex items-center gap-2">
                <.provider_icon provider_type={app.provider_type} class="size-4" />
                <.link
                  navigate={~p"/infrastructure/apps/#{app.id}"}
                  class="link link-hover text-sm"
                >
                  {app.name}
                </.link>
              </div>
              <.status_badge status={app.status} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp load_credentials do
    case Atlas.Providers.Credential.read() do
      {:ok, credentials} -> credentials
      _ -> []
    end
  end

  defp load_apps do
    case Atlas.Infrastructure.App.read() do
      {:ok, apps} -> apps
      _ -> []
    end
  end

  defp load_machines do
    case Atlas.Infrastructure.Machine.read() do
      {:ok, machines} -> machines
      _ -> []
    end
  end

  defp load_active_alerts do
    case Atlas.Monitoring.Alert.list_active() do
      {:ok, alerts} -> alerts
      _ -> []
    end
  end
end
