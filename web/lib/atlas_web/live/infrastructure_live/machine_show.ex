defmodule AtlasWeb.InfrastructureLive.MachineShow do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Atlas.Infrastructure.Machine.get_by_id(id) do
      {:ok, machine} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:app:#{machine.app_id}")
          Phoenix.PubSub.subscribe(Atlas.PubSub, "monitoring:health_check:#{machine.id}")
        end

        health_checks = load_health_checks(id)
        alerts = load_alerts(id)

        {:ok,
         assign(socket,
           page_title: machine.name || machine.provider_id,
           machine: machine,
           health_checks: health_checks,
           alerts: alerts,
           action_pending: nil
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Machine not found")
         |> push_navigate(to: ~p"/infrastructure")}
    end
  end

  @impl true
  def handle_info(%{topic: "infrastructure:app:" <> _}, socket) do
    machine = reload_machine(socket.assigns.machine.id)
    {:noreply, assign(socket, machine: machine, action_pending: nil)}
  end

  def handle_info(%{topic: "monitoring:health_check:" <> _}, socket) do
    health_checks = load_health_checks(socket.assigns.machine.id)
    {:noreply, assign(socket, health_checks: health_checks)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start_machine", _params, socket) do
    machine = socket.assigns.machine

    case Atlas.Monitoring.Workers.MachineActionWorker.enqueue_start(machine.id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(action_pending: :start)
         |> put_flash(:info, "Start action queued")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to queue start action")}
    end
  end

  def handle_event("stop_machine", _params, socket) do
    machine = socket.assigns.machine

    case Atlas.Monitoring.Workers.MachineActionWorker.enqueue_stop(machine.id) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(action_pending: :stop)
         |> put_flash(:info, "Stop action queued")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to queue stop action")}
    end
  end

  def handle_event("acknowledge_alert", %{"id" => alert_id}, socket) do
    case Atlas.Monitoring.Alert.get_by_id(alert_id) do
      {:ok, alert} ->
        Atlas.Monitoring.Alert.acknowledge(alert)
        alerts = load_alerts(socket.assigns.machine.id)
        {:noreply, assign(socket, alerts: alerts)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("resolve_alert", %{"id" => alert_id}, socket) do
    case Atlas.Monitoring.Alert.get_by_id(alert_id) do
      {:ok, alert} ->
        Atlas.Monitoring.Alert.resolve(alert)
        alerts = load_alerts(socket.assigns.machine.id)
        {:noreply, assign(socket, alerts: alerts)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        <div class="flex items-center gap-2">
          {@machine.name || @machine.provider_id}
          <.status_badge status={@machine.status} />
          <span
            :if={@action_pending}
            class="loading loading-spinner loading-xs text-primary"
          />
        </div>
        <:subtitle>
          Machine &middot; {@machine.region || "Unknown region"}
        </:subtitle>
        <:actions>
          <button
            :if={@machine.status in [:stopped, :created, :suspended]}
            phx-click="start_machine"
            class="btn btn-success btn-sm"
            disabled={@action_pending != nil}
          >
            <.icon name="hero-play" class="size-4" /> Start
          </button>
          <button
            :if={@machine.status == :started}
            phx-click="stop_machine"
            data-confirm="Are you sure you want to stop this machine?"
            class="btn btn-warning btn-sm"
            disabled={@action_pending != nil}
          >
            <.icon name="hero-stop" class="size-4" /> Stop
          </button>
        </:actions>
      </.header>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <.list>
            <:item title="Provider ID">{@machine.provider_id}</:item>
            <:item title="Status"><.status_badge status={@machine.status} /></:item>
            <:item title="Region">{@machine.region || "-"}</:item>
            <:item title="Image">{@machine.image || "-"}</:item>
            <:item title="CPU">
              {if @machine.cpu_kind, do: "#{@machine.cpus || "?"} x #{@machine.cpu_kind}", else: "-"}
            </:item>
            <:item title="Memory">
              {if @machine.memory_mb, do: format_memory(@machine.memory_mb), else: "-"}
            </:item>
            <:item :if={@machine.gpu_type} title="GPU">{@machine.gpu_type}</:item>
            <:item title="IP Addresses">
              {if @machine.ip_addresses != [],
                do: Enum.join(@machine.ip_addresses, ", "),
                else: "None"}
            </:item>
            <:item title="Last Synced">
              {if @machine.synced_at,
                do: Calendar.strftime(@machine.synced_at, "%Y-%m-%d %H:%M:%S UTC"),
                else: "Never"}
            </:item>
          </.list>
        </div>
      </div>

      <div :if={@alerts != []} class="card bg-base-100 shadow-sm border border-error/30">
        <div class="card-body">
          <h2 class="card-title text-base text-error">
            <.icon name="hero-exclamation-triangle" class="size-5" /> Alerts ({length(@alerts)})
          </h2>
          <div
            :for={alert <- @alerts}
            class="flex items-center justify-between py-2 border-b border-base-200 last:border-0"
          >
            <div>
              <span class={[
                "badge badge-sm mr-2",
                alert.severity == :critical && "badge-error",
                alert.severity == :warning && "badge-warning",
                alert.severity == :info && "badge-info"
              ]}>
                {alert.severity}
              </span>
              <span class="text-sm">{alert.title}</span>
              <span class="text-xs text-base-content/50 ml-2">
                <.status_badge status={alert.status} />
              </span>
            </div>
            <div class="flex gap-1">
              <button
                :if={alert.status == :firing}
                phx-click="acknowledge_alert"
                phx-value-id={alert.id}
                class="btn btn-ghost btn-xs"
              >
                Ack
              </button>
              <button
                :if={alert.status in [:firing, :acknowledged]}
                phx-click="resolve_alert"
                phx-value-id={alert.id}
                class="btn btn-ghost btn-xs"
              >
                Resolve
              </button>
            </div>
          </div>
        </div>
      </div>

      <div :if={@health_checks != []} class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base">Recent Health Checks</h2>
          <.table id="health-checks" rows={@health_checks}>
            <:col :let={hc} label="Status">
              <.status_badge status={hc.status} />
            </:col>
            <:col :let={hc} label="Response Time">
              {if hc.response_time_ms, do: "#{hc.response_time_ms}ms", else: "-"}
            </:col>
            <:col :let={hc} label="Time">
              {Calendar.strftime(hc.inserted_at, "%H:%M:%S")}
            </:col>
          </.table>
        </div>
      </div>

      <div class="flex gap-2">
        <.link navigate={~p"/infrastructure/apps/#{@machine.app_id}"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="size-4" /> Back to App
        </.link>
      </div>
    </div>
    """
  end

  defp format_memory(mb) when mb >= 1024, do: "#{div(mb, 1024)} GB"
  defp format_memory(mb), do: "#{mb} MB"

  defp reload_machine(id) do
    case Atlas.Infrastructure.Machine.get_by_id(id) do
      {:ok, machine} -> machine
      _ -> nil
    end
  end

  defp load_health_checks(machine_id) do
    case Atlas.Monitoring.HealthCheck.recent(machine_id) do
      {:ok, checks} -> checks
      _ -> []
    end
  end

  defp load_alerts(machine_id) do
    case Atlas.Monitoring.Alert.by_machine(machine_id) do
      {:ok, alerts} -> Enum.filter(alerts, &(&1.status != :resolved))
      _ -> []
    end
  end
end
