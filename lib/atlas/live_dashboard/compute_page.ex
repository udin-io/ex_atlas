if Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder) do
  defmodule Atlas.LiveDashboard.ComputePage do
    @moduledoc """
    `Phoenix.LiveDashboard.PageBuilder` page that lists the compute resources
    currently tracked by `Atlas.Orchestrator` and lets operators terminate them.

    The page only compiles when the host app has `:phoenix_live_dashboard` in
    its dependency tree (guarded by `Code.ensure_loaded?/1`), so library users
    who don't run LiveDashboard pay nothing.

    ## Wiring

    Add `:phoenix_live_dashboard` and `:atlas` to your Phoenix app's deps, then
    extend your existing `live_dashboard` route:

        # lib/my_app_web/router.ex
        import Phoenix.LiveDashboard.Router

        scope "/" do
          pipe_through [:browser, :require_admin]

          live_dashboard "/dashboard",
            metrics: MyAppWeb.Telemetry,
            allow_destructive_actions: true,
            additional_pages: [
              atlas: Atlas.LiveDashboard.ComputePage
            ]
        end

    `allow_destructive_actions: true` is required for the Terminate/Stop
    buttons to render — mirrors the built-in "Kill process" convention.

    Open `/dashboard/atlas` to see the table. The page needs the orchestrator
    supervision tree; enable it via `config :atlas, start_orchestrator: true`.

    ## What it shows

      * Every tracked compute resource (`Atlas.Orchestrator.list_ids/0`).
      * Provider, status, GPU type, cost/hour, last-activity age.
      * Per-row **Touch**, **Stop**, **Terminate** buttons.

    ## Live updates

    Auto-refresh is on (`refresher?: true`), so the table polls at the
    dashboard's configured interval. For sub-poll latency the page also
    subscribes to `Atlas.PubSub` when the socket connects.
    """

    use Phoenix.LiveDashboard.PageBuilder, refresher?: true

    alias Atlas.Orchestrator

    @impl true
    def init(_opts), do: {:ok, %{}, application: :atlas}

    @impl true
    def menu_link(_session, _capabilities), do: {:ok, "Atlas"}

    @impl true
    def mount(_params, _session, socket) do
      if connected?(socket) and pubsub_available?() do
        Phoenix.PubSub.subscribe(Atlas.PubSub, "atlas:compute")
      end

      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <.live_table
        id="atlas-compute-table"
        dom_id="atlas-compute-table"
        page={@page}
        title="Atlas compute"
        row_fetcher={&fetch_rows/2}
        rows_name="resources"
      >
        <:col field={:id} header="ID" />
        <:col field={:provider} header="Provider" />
        <:col field={:status} header="Status" sortable={:asc} />
        <:col field={:gpu_type} header="GPU" />
        <:col field={:cost_per_hour} header="$/hr" text_align="right" />
        <:col field={:idle_for} header="Idle" text_align="right" />
        <:col :let={row} field={:actions} header="Actions">
          <.actions row={row} allow={@page.allow_destructive_actions} />
        </:col>
      </.live_table>
      """
    end

    defp actions(assigns) do
      ~H"""
      <div class="btn-group btn-group-sm" role="group">
        <button class="btn btn-outline-secondary btn-sm"
                phx-click="touch" phx-value-id={@row.id}
                phx-page-loading>
          Touch
        </button>
        <button :if={@allow}
                class="btn btn-outline-warning btn-sm"
                phx-click="stop" phx-value-id={@row.id}
                data-confirm={"Stop #{@row.id}?"}
                phx-page-loading>
          Stop
        </button>
        <button :if={@allow}
                class="btn btn-outline-danger btn-sm"
                phx-click="terminate" phx-value-id={@row.id}
                data-confirm={"Terminate #{@row.id}? This is irreversible."}
                phx-page-loading>
          Terminate
        </button>
      </div>
      """
    end

    @impl true
    def handle_event("touch", %{"id" => id}, socket) do
      _ = Orchestrator.touch(id)
      {:noreply, socket}
    end

    def handle_event("stop", %{"id" => id}, socket) do
      _ = Atlas.stop(id)
      {:noreply, socket}
    end

    def handle_event("terminate", %{"id" => id}, socket) do
      _ = Orchestrator.stop_tracked(id)
      {:noreply, socket}
    end

    @impl true
    def handle_info({:atlas_compute, _id, _event}, socket), do: {:noreply, socket}
    def handle_info(_msg, socket), do: {:noreply, socket}

    @doc false
    def fetch_rows(%{search: search, sort_by: sort_by, sort_dir: sort_dir, limit: limit}, _node) do
      rows =
        Orchestrator.list_ids()
        |> Enum.map(&build_row/1)
        |> Enum.reject(&is_nil/1)
        |> maybe_filter(search)
        |> Enum.sort_by(&Map.get(&1, sort_by), sort_dir)

      {Enum.take(rows, limit), length(rows)}
    end

    @doc false
    def build_row(id) do
      case Orchestrator.info(id) do
        {:ok, %{compute: compute, last_activity_ms: activity, user_id: user_id}} ->
          %{
            id: compute.id,
            provider: inspect(compute.provider),
            status: to_string(compute.status),
            gpu_type: compute.gpu_type,
            cost_per_hour: format_cost(compute.cost_per_hour),
            idle_for: idle_seconds(activity),
            user_id: inspect(user_id)
          }

        _ ->
          nil
      end
    end

    defp maybe_filter(rows, nil), do: rows
    defp maybe_filter(rows, ""), do: rows

    defp maybe_filter(rows, search) when is_binary(search) do
      needle = String.downcase(search)
      Enum.filter(rows, &String.contains?(String.downcase(&1.id), needle))
    end

    defp format_cost(nil), do: "-"
    defp format_cost(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 4)
    defp format_cost(other), do: to_string(other)

    defp idle_seconds(activity_ms) when is_integer(activity_ms) do
      div(System.monotonic_time(:millisecond) - activity_ms, 1_000)
    end

    defp idle_seconds(_), do: nil

    defp pubsub_available? do
      Code.ensure_loaded?(Phoenix.PubSub) and Process.whereis(Atlas.PubSub) != nil
    end
  end
end
