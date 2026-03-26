defmodule AtlasWeb.ProviderLive.FormLive do
  use AtlasWeb, :live_view

  alias Atlas.Providers.Adapters.Fly.{CliDetector, Client}

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       test_result: nil,
       cli_detect_status: nil,
       detected_orgs: [],
       orgs_loading: false,
       req_options: [],
       cli_detector_opts: []
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    form =
      Atlas.Providers.Credential
      |> AshPhoenix.Form.for_create(:create,
        forms: [auto?: true]
      )
      |> to_form()

    assign(socket,
      page_title: "New Provider",
      credential: nil,
      form: form
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Atlas.Providers.Credential.get_by_id(id) do
      {:ok, credential} ->
        form =
          credential
          |> AshPhoenix.Form.for_update(:update,
            forms: [auto?: true]
          )
          |> to_form()

        assign(socket,
          page_title: "Edit Provider",
          credential: credential,
          form: form
        )

      {:error, _} ->
        socket
        |> put_flash(:error, "Provider not found")
        |> push_navigate(to: ~p"/providers")
    end
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.form.source, params) |> to_form()

    prev_type = current_provider_type(socket.assigns.form)
    new_type = params["provider_type"]

    socket =
      if prev_type != new_type do
        assign(socket, cli_detect_status: nil, detected_orgs: [])
      else
        socket
      end

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form.source, params: params) do
      {:ok, credential} ->
        if socket.assigns.live_action == :new do
          Atlas.Providers.SyncManager.start_sync(credential.id)
        else
          Atlas.Providers.SyncManager.restart_sync(credential.id)
        end

        {:noreply,
         socket
         |> put_flash(:info, "Provider saved successfully")
         |> push_navigate(to: ~p"/providers/#{credential.id}")}

      {:error, form} ->
        {:noreply, assign(socket, form: to_form(form))}
    end
  end

  def handle_event("detect_cli_token", _params, socket) do
    case CliDetector.detect(socket.assigns.cli_detector_opts) do
      {:ok, token} ->
        # Update the form with the detected token
        params = socket.assigns.form.source |> AshPhoenix.Form.params()
        updated_params = Map.put(params, "api_token", token)
        form = AshPhoenix.Form.validate(socket.assigns.form.source, updated_params) |> to_form()

        {:noreply, assign(socket, form: form, cli_detect_status: :detected)}

      :not_found ->
        {:noreply,
         assign(socket,
           cli_detect_status: {:error, "No Fly.io CLI token found. Run `fly auth login` first."}
         )}
    end
  end

  def handle_event("fetch_orgs", _params, socket) do
    api_token =
      socket.assigns.form.source |> AshPhoenix.Form.params() |> Map.get("api_token")

    if api_token && api_token != "" do
      req_options = socket.assigns.req_options

      Task.Supervisor.async_nolink(Atlas.TaskSupervisor, fn ->
        case Client.new(api_token) do
          {:ok, client} -> Client.list_orgs(client, req_options)
          {:error, _} = error -> error
        end
      end)

      {:noreply, assign(socket, orgs_loading: true)}
    else
      {:noreply, assign(socket, cli_detect_status: {:error, "Enter an API token first"})}
    end
  end

  def handle_event("select_org", %{"slug" => slug}, socket) do
    params = socket.assigns.form.source |> AshPhoenix.Form.params()
    updated_params = Map.put(params, "org_slug", slug)
    form = AshPhoenix.Form.validate(socket.assigns.form.source, updated_params) |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("test_connection", _params, socket) do
    form_params = socket.assigns.form.source |> AshPhoenix.Form.params()
    provider_type = form_params["provider_type"]
    api_token = form_params["api_token"]
    org_slug = form_params["org_slug"]

    if provider_type && api_token do
      provider_atom =
        case provider_type do
          "fly" -> :fly
          "runpod" -> :runpod
          other when is_atom(other) -> other
          _ -> nil
        end

      if provider_atom do
        case Atlas.Providers.Adapter.adapter_for(provider_atom) do
          {:ok, adapter} ->
            fake_credential = %{api_token: api_token, org_slug: org_slug}

            case adapter.test_connection(fake_credential) do
              :ok ->
                {:noreply, assign(socket, test_result: :ok)}

              {:error, reason} ->
                {:noreply, assign(socket, test_result: {:error, reason})}
            end

          {:error, _} ->
            {:noreply, assign(socket, test_result: {:error, "Unknown provider type"})}
        end
      else
        {:noreply, assign(socket, test_result: {:error, "Select a provider type first"})}
      end
    else
      {:noreply,
       assign(socket, test_result: {:error, "Fill in provider type and API token first"})}
    end
  end

  @impl true
  def handle_info({ref, {:ok, %{status: 200, body: body}}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    nodes = get_in(body, ["data", "organizations", "nodes"]) || []

    orgs =
      Enum.map(nodes, fn node ->
        {node["name"], node["slug"]}
      end)

    {:noreply, assign(socket, detected_orgs: orgs, orgs_loading: false)}
  end

  def handle_info({ref, {:ok, %{status: status}}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       detected_orgs: [],
       orgs_loading: false,
       cli_detect_status: {:error, "Failed to fetch orgs (HTTP #{status})"}
     )}
  end

  def handle_info({ref, {:error, _}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       detected_orgs: [],
       orgs_loading: false,
       cli_detect_status: {:error, "Failed to connect to Fly.io API"}
     )}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, assign(socket, orgs_loading: false)}
  end

  @impl true
  def handle_info({:set_req_options, options}, socket) do
    {:noreply, assign(socket, req_options: options)}
  end

  @impl true
  def handle_info({:set_cli_detector_opts, opts}, socket) do
    {:noreply, assign(socket, cli_detector_opts: opts)}
  end

  defp current_provider_type(form) do
    form.source |> AshPhoenix.Form.params() |> Map.get("provider_type")
  end

  defp fly_selected?(form) do
    current_provider_type(form) == "fly"
  end

  defp has_api_token?(form) do
    token = form.source |> AshPhoenix.Form.params() |> Map.get("api_token")
    token && token != ""
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:fly_selected, fly_selected?(assigns.form))
      |> assign(:has_token, has_api_token?(assigns.form))

    ~H"""
    <div class="max-w-xl mx-auto space-y-6">
      <.header>
        {@page_title}
        <:subtitle>
          <%= if @live_action == :new do %>
            Connect a new infrastructure provider
          <% else %>
            Update provider connection settings
          <% end %>
        </:subtitle>
      </.header>

      <div class="card bg-base-100 shadow-sm border border-base-300">
        <div class="card-body">
          <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-4">
            <.input
              field={@form[:provider_type]}
              type="select"
              label="Provider"
              options={[{"Fly.io", "fly"}, {"RunPod", "runpod"}]}
              prompt="Select a provider..."
            />

            <.input field={@form[:name]} label="Name" placeholder="My Fly.io account" />
            <.input field={@form[:api_token]} type="password" label="API Token" placeholder="fo1_..." />

            <div :if={@fly_selected} class="flex items-center gap-2 -mt-2">
              <button type="button" phx-click="detect_cli_token" class="btn btn-ghost btn-xs">
                <.icon name="hero-command-line" class="size-3" /> Detect from CLI
              </button>
              <span
                :if={@cli_detect_status == :detected}
                data-role="cli-detect-success"
                class="badge badge-success badge-sm gap-1"
              >
                <.icon name="hero-check-circle" class="size-3" /> Token detected
              </span>
              <span
                :if={match?({:error, _}, @cli_detect_status)}
                data-role="cli-detect-error"
                class="text-error text-xs"
              >
                {elem(@cli_detect_status, 1)}
              </span>
            </div>

            <.input field={@form[:org_slug]} label="Organization Slug" placeholder="personal" />

            <div :if={@fly_selected && @has_token} class="flex flex-wrap items-center gap-2 -mt-2">
              <button
                type="button"
                phx-click="fetch_orgs"
                class="btn btn-ghost btn-xs"
                disabled={@orgs_loading}
              >
                <span :if={@orgs_loading} class="loading loading-spinner loading-xs"></span>
                <.icon :if={!@orgs_loading} name="hero-building-office" class="size-3" />
                {if @orgs_loading, do: "Fetching...", else: "Fetch Organizations"}
              </button>
              <button
                :for={{name, slug} <- @detected_orgs}
                type="button"
                phx-click="select_org"
                phx-value-slug={slug}
                data-role="org-badge"
                class="badge badge-outline badge-sm cursor-pointer hover:badge-primary"
              >
                {name} ({slug})
              </button>
            </div>

            <div class="divider text-xs">Sync Settings</div>

            <.input field={@form[:sync_enabled]} type="checkbox" label="Enable auto-sync" />
            <.input
              field={@form[:sync_interval_seconds]}
              type="number"
              label="Sync interval (seconds)"
              min="10"
              max="3600"
            />

            <div class="flex items-center gap-2">
              <button type="button" phx-click="test_connection" class="btn btn-outline btn-sm">
                <.icon name="hero-signal" class="size-4" /> Test Connection
              </button>
              <span :if={@test_result == :ok} class="text-success text-sm">
                Connection successful
              </span>
              <span :if={match?({:error, _}, @test_result)} class="text-error text-sm">
                {elem(@test_result, 1)}
              </span>
            </div>

            <div class="flex justify-end gap-2 pt-4">
              <.link navigate={~p"/providers"} class="btn btn-ghost">Cancel</.link>
              <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">
                Save Provider
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
