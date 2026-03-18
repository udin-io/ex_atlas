defmodule AtlasWeb.ProviderLive.Index do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Atlas.PubSub, "providers:credentials")
    end

    {:ok, assign(socket, page_title: "Providers", credentials: load_credentials())}
  end

  @impl true
  def handle_info(%{topic: "providers:credentials"}, socket) do
    {:noreply, assign(socket, credentials: load_credentials())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Atlas.Providers.Credential.get_by_id(id) do
      {:ok, credential} ->
        Atlas.Providers.Credential.destroy(credential)
        Atlas.Providers.SyncManager.stop_sync(id)
        {:noreply, assign(socket, credentials: load_credentials())}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Providers
        <:subtitle>Manage infrastructure provider connections</:subtitle>
        <:actions>
          <.link navigate={~p"/providers/new"} class="btn btn-primary btn-sm">
            <.icon name="hero-plus" class="size-4" /> Add Provider
          </.link>
        </:actions>
      </.header>

      <div :if={@credentials == []} class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-server-stack" class="size-12 text-base-content/30" />
          <h3 class="font-medium mt-2">No providers configured</h3>
          <p class="text-sm text-base-content/60">
            Add a provider to start monitoring your infrastructure.
          </p>
          <.link navigate={~p"/providers/new"} class="btn btn-primary btn-sm mt-4">
            Add Provider
          </.link>
        </div>
      </div>

      <div :if={@credentials != []} class="overflow-x-auto">
        <.table id="credentials" rows={@credentials}>
          <:col :let={cred} label="Provider">
            <div class="flex items-center gap-2">
              <.provider_icon provider_type={cred.provider_type} class="size-4" />
              <span class="font-medium">{String.upcase(to_string(cred.provider_type))}</span>
            </div>
          </:col>
          <:col :let={cred} label="Name">
            <.link navigate={~p"/providers/#{cred.id}"} class="link link-hover">
              {cred.name}
            </.link>
          </:col>
          <:col :let={cred} label="Status">
            <.status_badge status={cred.status} />
          </:col>
          <:col :let={cred} label="Sync">
            <.sync_status credential={cred} />
          </:col>
          <:action :let={cred}>
            <.link navigate={~p"/providers/#{cred.id}/edit"} class="btn btn-ghost btn-xs">
              Edit
            </.link>
          </:action>
          <:action :let={cred}>
            <button
              phx-click="delete"
              phx-value-id={cred.id}
              data-confirm="Are you sure you want to delete this provider?"
              class="btn btn-ghost btn-xs text-error"
            >
              Delete
            </button>
          </:action>
        </.table>
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
end
