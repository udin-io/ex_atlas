defmodule AtlasWeb.InfrastructureLive.AppShow do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Atlas.Infrastructure.App.get_by_id(id) do
      {:ok, app} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:app:#{id}")
          Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:credential:#{app.credential_id}")
        end

        machines = load_machines(id)
        volumes = load_volumes(id)

        {:ok,
         assign(socket,
           page_title: app.name,
           app: app,
           machines: machines,
           volumes: volumes
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "App not found")
         |> push_navigate(to: ~p"/infrastructure")}
    end
  end

  @impl true
  def handle_info(%{topic: "infrastructure:app:" <> _}, socket) do
    app_id = socket.assigns.app.id
    machines = load_machines(app_id)
    volumes = load_volumes(app_id)
    app = reload_app(app_id)
    {:noreply, assign(socket, app: app, machines: machines, volumes: volumes)}
  end

  def handle_info(%{topic: "infrastructure:credential:" <> _}, socket) do
    app = reload_app(socket.assigns.app.id)
    {:noreply, assign(socket, app: app)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        <div class="flex items-center gap-2">
          <.provider_icon provider_type={@app.provider_type} class="size-5" />
          {@app.name}
          <.status_badge status={@app.status} />
        </div>
        <:subtitle>
          {String.upcase(to_string(@app.provider_type))} app
          <%= if @app.region do %>
            &middot; {@app.region}
          <% end %>
        </:subtitle>
      </.header>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <.list>
            <:item title="Provider ID">{@app.provider_id}</:item>
            <:item title="Status"><.status_badge status={@app.status} /></:item>
            <:item title="Machines">{length(@machines)}</:item>
            <:item title="Volumes">{length(@volumes)}</:item>
            <:item title="Last Synced">
              <%= if @app.synced_at do %>
                {Calendar.strftime(@app.synced_at, "%Y-%m-%d %H:%M:%S UTC")}
              <% else %>
                Never
              <% end %>
            </:item>
          </.list>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base">Machines ({length(@machines)})</h2>
          <div :if={@machines == []} class="text-sm text-base-content/60 py-4">
            No machines found for this app.
          </div>
          <div :if={@machines != []} class="overflow-x-auto">
            <.table id="machines" rows={@machines}>
              <:col :let={machine} label="Name">
                <.link
                  navigate={~p"/infrastructure/machines/#{machine.id}"}
                  class="link link-hover font-medium"
                >
                  {machine.name || machine.provider_id}
                </.link>
              </:col>
              <:col :let={machine} label="Region">{machine.region || "-"}</:col>
              <:col :let={machine} label="Status">
                <.status_badge status={machine.status} />
              </:col>
              <:col :let={machine} label="Specs">
                <.spec_list machine={machine} />
              </:col>
            </.table>
          </div>
        </div>
      </div>

      <div :if={@volumes != []} class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base">Volumes ({length(@volumes)})</h2>
          <.table id="volumes" rows={@volumes}>
            <:col :let={vol} label="Name">{vol.name}</:col>
            <:col :let={vol} label="Size">{vol.size_gb} GB</:col>
            <:col :let={vol} label="Region">{vol.region || "-"}</:col>
            <:col :let={vol} label="Status">{vol.status}</:col>
          </.table>
        </div>
      </div>
    </div>
    """
  end

  defp load_machines(app_id) do
    case Atlas.Infrastructure.Machine.by_app(app_id) do
      {:ok, machines} -> machines
      _ -> []
    end
  end

  defp load_volumes(app_id) do
    case Atlas.Infrastructure.Volume.by_app(app_id) do
      {:ok, volumes} -> volumes
      _ -> []
    end
  end

  defp reload_app(id) do
    case Atlas.Infrastructure.App.get_by_id(id) do
      {:ok, app} -> app
      _ -> nil
    end
  end
end
