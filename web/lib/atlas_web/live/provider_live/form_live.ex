defmodule AtlasWeb.ProviderLive.FormLive do
  use AtlasWeb, :live_view

  on_mount {AtlasWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, test_result: nil)}
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
  def render(assigns) do
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
            <.input field={@form[:org_slug]} label="Organization Slug" placeholder="personal" />

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
