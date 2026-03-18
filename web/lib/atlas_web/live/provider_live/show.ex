defmodule AtlasWeb.ProviderLive.Show do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Atlas.Providers.Credential.get_by_id(id) do
      {:ok, credential} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:credential:#{id}")
          Phoenix.PubSub.subscribe(Atlas.PubSub, "providers:credentials")
        end

        apps = load_apps(id)

        {:ok,
         assign(socket,
           page_title: credential.name,
           credential: credential,
           apps: apps
         )}

      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Provider not found")
         |> push_navigate(to: ~p"/providers")}
    end
  end

  @impl true
  def handle_info(%{topic: "infrastructure:credential:" <> _}, socket) do
    credential = reload_credential(socket.assigns.credential.id)
    apps = load_apps(socket.assigns.credential.id)
    {:noreply, assign(socket, credential: credential, apps: apps)}
  end

  def handle_info(%{topic: "providers:credentials"}, socket) do
    credential = reload_credential(socket.assigns.credential.id)
    {:noreply, assign(socket, credential: credential)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("trigger_sync", _params, socket) do
    Atlas.Providers.SyncManager.restart_sync(socket.assigns.credential.id)
    {:noreply, put_flash(socket, :info, "Sync triggered")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        <div class="flex items-center gap-2">
          <.provider_icon provider_type={@credential.provider_type} class="size-5" />
          {@credential.name}
          <.status_badge status={@credential.status} />
        </div>
        <:subtitle>
          {String.upcase(to_string(@credential.provider_type))} provider
          <%= if @credential.org_slug do %>
            &middot; Org: {@credential.org_slug}
          <% end %>
        </:subtitle>
        <:actions>
          <.link navigate={~p"/providers/#{@credential.id}/edit"} class="btn btn-ghost btn-sm">
            <.icon name="hero-pencil" class="size-4" /> Edit
          </.link>
          <button phx-click="trigger_sync" class="btn btn-outline btn-sm">
            <.icon name="hero-arrow-path" class="size-4" /> Sync Now
          </button>
        </:actions>
      </.header>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <.list>
            <:item title="Status">
              <.status_badge status={@credential.status} />
              <span :if={@credential.status_message} class="ml-2 text-sm text-error">
                {@credential.status_message}
              </span>
            </:item>
            <:item title="Sync">
              <.sync_status credential={@credential} />
            </:item>
            <:item title="Sync Interval">{@credential.sync_interval_seconds}s</:item>
            <:item title="Auto-Sync">
              {if @credential.sync_enabled, do: "Enabled", else: "Disabled"}
            </:item>
            <:item title="Apps Discovered">{length(@apps)}</:item>
          </.list>
        </div>
      </div>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <h2 class="card-title text-base">Apps</h2>
          <div :if={@apps == []} class="text-sm text-base-content/60 py-4">
            No apps discovered yet. Sync may still be in progress.
          </div>
          <div :if={@apps != []} class="grid grid-cols-1 md:grid-cols-2 gap-3">
            <.link :for={app <- @apps} navigate={~p"/infrastructure/apps/#{app.id}"}>
              <.resource_card app={app} class="hover:border-primary transition-colors" />
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp load_apps(credential_id) do
    case Atlas.Infrastructure.App.by_credential(credential_id) do
      {:ok, apps} -> apps
      _ -> []
    end
  end

  defp reload_credential(id) do
    case Atlas.Providers.Credential.get_by_id(id) do
      {:ok, cred} -> cred
      _ -> nil
    end
  end
end
