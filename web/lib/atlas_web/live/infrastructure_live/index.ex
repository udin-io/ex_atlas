defmodule AtlasWeb.InfrastructureLive.Index do
  use AtlasWeb, :live_view

  import AtlasWeb.InfrastructureComponents

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    credentials = load_credentials()

    if connected?(socket) do
      Enum.each(credentials, fn cred ->
        Phoenix.PubSub.subscribe(Atlas.PubSub, "infrastructure:credential:#{cred.id}")
      end)
    end

    all_apps = load_apps()

    {:ok,
     assign(socket,
       page_title: "Infrastructure",
       all_apps: all_apps,
       apps: all_apps,
       credentials: credentials,
       filter_provider: nil,
       filter_status: nil,
       search: ""
     )}
  end

  @impl true
  def handle_info(%{topic: "infrastructure:credential:" <> _}, socket) do
    all_apps = load_apps()

    {:noreply,
     socket
     |> assign(all_apps: all_apps)
     |> apply_filters()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    provider = params["provider"] || ""
    status = params["status"] || ""
    search = params["search"] || ""

    provider_filter = if provider == "", do: nil, else: String.to_existing_atom(provider)
    status_filter = if status == "", do: nil, else: String.to_existing_atom(status)

    {:noreply,
     socket
     |> assign(
       filter_provider: provider_filter,
       filter_status: status_filter,
       search: search
     )
     |> apply_filters()}
  end

  defp apply_filters(socket) do
    filtered =
      socket.assigns.all_apps
      |> maybe_filter_provider(socket.assigns.filter_provider)
      |> maybe_filter_status(socket.assigns.filter_status)
      |> maybe_search(socket.assigns.search)

    assign(socket, apps: filtered)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.header>
        Infrastructure
        <:subtitle>{length(@apps)} apps across {length(@credentials)} providers</:subtitle>
      </.header>

      <.form for={%{}} phx-change="filter" class="flex flex-wrap gap-2">
        <input
          type="text"
          name="search"
          value={@search}
          placeholder="Search apps..."
          class="input input-sm input-bordered w-60"
          phx-debounce="200"
        />
        <select name="provider" class="select select-sm select-bordered">
          <option value="">All Providers</option>
          <option value="fly" selected={@filter_provider == :fly}>Fly.io</option>
          <option value="runpod" selected={@filter_provider == :runpod}>RunPod</option>
        </select>
        <select name="status" class="select select-sm select-bordered">
          <option value="">All Statuses</option>
          <option value="deployed" selected={@filter_status == :deployed}>Deployed</option>
          <option value="suspended" selected={@filter_status == :suspended}>Suspended</option>
          <option value="pending" selected={@filter_status == :pending}>Pending</option>
          <option value="error" selected={@filter_status == :error}>Error</option>
        </select>
      </.form>

      <div :if={@apps == []} class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body items-center text-center py-12">
          <.icon name="hero-cube-transparent" class="size-12 text-base-content/30" />
          <h3 class="font-medium mt-2">No apps found</h3>
          <p class="text-sm text-base-content/60">
            {if @search != "" || @filter_provider || @filter_status,
              do: "Try adjusting your filters.",
              else: "Apps will appear here after providers sync their data."}
          </p>
        </div>
      </div>

      <div :if={@apps != []} class="overflow-x-auto">
        <.table id="apps" rows={@apps}>
          <:col :let={app} label="App">
            <div class="flex items-center gap-2">
              <.provider_icon provider_type={app.provider_type} class="size-4" />
              <.link
                navigate={~p"/infrastructure/apps/#{app.id}"}
                class="link link-hover font-medium"
              >
                {app.name}
              </.link>
            </div>
          </:col>
          <:col :let={app} label="Provider">
            {String.upcase(to_string(app.provider_type))}
          </:col>
          <:col :let={app} label="Region">
            {app.region || "-"}
          </:col>
          <:col :let={app} label="Status">
            <.status_badge status={app.status} />
          </:col>
        </.table>
      </div>
    </div>
    """
  end

  defp load_credentials do
    case Atlas.Providers.Credential.read() do
      {:ok, creds} -> creds
      _ -> []
    end
  end

  defp load_apps do
    case Atlas.Infrastructure.App.read() do
      {:ok, apps} -> apps
      _ -> []
    end
  end

  defp maybe_filter_provider(apps, nil), do: apps

  defp maybe_filter_provider(apps, provider),
    do: Enum.filter(apps, &(&1.provider_type == provider))

  defp maybe_filter_status(apps, nil), do: apps
  defp maybe_filter_status(apps, status), do: Enum.filter(apps, &(&1.status == status))

  defp maybe_search(apps, ""), do: apps
  defp maybe_search(apps, nil), do: apps

  defp maybe_search(apps, term) do
    downcased = String.downcase(term)

    Enum.filter(apps, fn app ->
      String.contains?(String.downcase(app.name), downcased) ||
        (app.region && String.contains?(String.downcase(app.region), downcased))
    end)
  end
end
