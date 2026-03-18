defmodule AtlasWeb.TopologyLive do
  use AtlasWeb, :live_view

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    credentials = load_credentials()

    if connected?(socket) do
      Enum.each(credentials, fn cred ->
        Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:credential:#{cred.id}")
      end)
    end

    graph = build_graph()

    {:ok,
     socket
     |> assign(page_title: "Topology", graph: graph)
     |> push_topology_data(graph)}
  end

  @impl true
  def handle_info(%{topic: "infrastructure:credential:" <> _}, socket) do
    graph = build_graph()

    {:noreply,
     socket
     |> assign(graph: graph)
     |> push_event("topology_data", graph)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("navigate", %{"path" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <.header>
        Topology
        <:subtitle>Interactive infrastructure topology map</:subtitle>
      </.header>

      <div class="flex gap-4 text-xs text-base-content/60">
        <div class="flex items-center gap-1">
          <span class="size-3 rounded bg-success/30 border border-success"></span> Running
        </div>
        <div class="flex items-center gap-1">
          <span class="size-3 rounded bg-warning/30 border border-warning"></span> Stopped/Suspended
        </div>
        <div class="flex items-center gap-1">
          <span class="size-3 rounded bg-error/30 border border-error"></span> Error
        </div>
        <div class="flex items-center gap-1">
          <span class="size-3 rounded bg-base-content/10 border border-base-content/30"></span>
          Destroyed
        </div>
        <div class="ml-auto text-base-content/40">
          Drag to reposition &middot; Scroll to zoom &middot; Click to navigate
        </div>
      </div>

      <div
        id="topology-graph"
        phx-hook="TopologyHook"
        phx-update="ignore"
        class="w-full h-[calc(100vh-12rem)] bg-base-200 rounded-box relative"
      >
      </div>
    </div>
    """
  end

  defp push_topology_data(socket, graph) do
    if connected?(socket) do
      push_event(socket, "topology_data", graph)
    else
      socket
    end
  end

  defp build_graph do
    apps = load_apps()
    machines = load_machines()
    volumes = load_volumes()

    nodes = build_nodes(apps, machines, volumes)
    links = build_links(apps, machines, volumes)

    %{nodes: nodes, links: links}
  end

  defp build_nodes(apps, machines, volumes) do
    app_nodes =
      Enum.map(apps, fn app ->
        %{
          id: "app-#{app.id}",
          type: "app",
          label: app.name,
          status: to_string(app.status),
          provider: to_string(app.provider_type),
          region: app.region,
          navigate_to: "/infrastructure/apps/#{app.id}"
        }
      end)

    machine_nodes =
      Enum.map(machines, fn m ->
        %{
          id: "machine-#{m.id}",
          type: "machine",
          label: m.name || m.provider_id,
          status: to_string(m.status),
          provider: nil,
          region: m.region,
          navigate_to: "/infrastructure/machines/#{m.id}"
        }
      end)

    volume_nodes =
      Enum.map(volumes, fn v ->
        %{
          id: "volume-#{v.id}",
          type: "volume",
          label: v.name,
          status: v.status || "created",
          provider: nil,
          region: v.region,
          navigate_to: nil
        }
      end)

    app_nodes ++ machine_nodes ++ volume_nodes
  end

  defp build_links(_apps, machines, volumes) do
    machine_links =
      Enum.map(machines, fn m ->
        %{
          source: "app-#{m.app_id}",
          target: "machine-#{m.id}",
          type: "contains"
        }
      end)

    volume_links =
      Enum.map(volumes, fn v ->
        %{
          source: "app-#{v.app_id}",
          target: "volume-#{v.id}",
          type: "attached_to"
        }
      end)

    machine_links ++ volume_links
  end

  defp load_credentials do
    case Atlas.Providers.Credential.read() do
      {:ok, creds} -> creds
      _ -> []
    end
  end

  defp load_apps do
    case Atlas.Infrastructure.App.read() do
      {:ok, apps} -> Enum.filter(apps, &(&1.status != :destroyed))
      _ -> []
    end
  end

  defp load_machines do
    case Atlas.Infrastructure.Machine.read() do
      {:ok, machines} -> Enum.filter(machines, &(&1.status != :destroyed))
      _ -> []
    end
  end

  defp load_volumes do
    case Atlas.Infrastructure.Volume.read() do
      {:ok, volumes} -> volumes
      _ -> []
    end
  end
end
