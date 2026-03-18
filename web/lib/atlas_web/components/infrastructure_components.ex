defmodule AtlasWeb.InfrastructureComponents do
  @moduledoc """
  UI components for infrastructure resources.
  """
  use Phoenix.Component

  attr :status, :atom, required: true
  attr :class, :string, default: nil

  def status_badge(assigns) do
    color =
      case assigns.status do
        s when s in [:deployed, :started, :active] -> "badge-success"
        s when s in [:suspended, :stopped] -> "badge-warning"
        s when s in [:error] -> "badge-error"
        s when s in [:destroyed, :disabled] -> "badge-neutral"
        _ -> "badge-info"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={["badge badge-sm", @color, @class]}>
      {to_string(@status)}
    </span>
    """
  end

  attr :provider_type, :atom, required: true
  attr :class, :string, default: "size-5"

  def provider_icon(assigns) do
    ~H"""
    <span class={["inline-flex items-center justify-center", @class]}>
      <%= case @provider_type do %>
        <% :fly -> %>
          <svg viewBox="0 0 24 24" fill="currentColor" class={@class}>
            <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z" />
          </svg>
        <% :runpod -> %>
          <svg viewBox="0 0 24 24" fill="currentColor" class={@class}>
            <path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5" />
          </svg>
        <% _ -> %>
          <span class="hero-server size-5" />
      <% end %>
    </span>
    """
  end

  attr :app, :map, required: true
  attr :class, :string, default: nil

  def resource_card(assigns) do
    ~H"""
    <div class={["card bg-base-100 shadow-sm border border-base-300", @class]}>
      <div class="card-body p-4">
        <div class="flex items-center gap-2">
          <.provider_icon provider_type={@app.provider_type} class="size-4" />
          <h3 class="card-title text-sm font-medium">{@app.name}</h3>
          <.status_badge status={@app.status} />
        </div>
        <div class="text-xs text-base-content/60 mt-1">
          <span :if={@app.region}>Region: {@app.region}</span>
        </div>
      </div>
    </div>
    """
  end

  attr :machine, :map, required: true
  attr :class, :string, default: nil

  def spec_list(assigns) do
    ~H"""
    <div class={["flex flex-wrap gap-2 text-xs", @class]}>
      <span :if={@machine.cpu_kind} class="badge badge-outline badge-sm">
        {@machine.cpu_kind}
      </span>
      <span :if={@machine.cpus} class="badge badge-outline badge-sm">
        {@machine.cpus} vCPU
      </span>
      <span :if={@machine.memory_mb} class="badge badge-outline badge-sm">
        {format_memory(@machine.memory_mb)}
      </span>
      <span :if={@machine.gpu_type} class="badge badge-outline badge-sm badge-accent">
        {@machine.gpu_type}
      </span>
    </div>
    """
  end

  attr :credential, :map, required: true
  attr :class, :string, default: nil

  def sync_status(assigns) do
    ~H"""
    <div class={["flex items-center gap-2 text-xs", @class]}>
      <span class={[
        "size-2 rounded-full",
        @credential.status == :active && "bg-success",
        @credential.status == :error && "bg-error",
        @credential.status == :disabled && "bg-base-content/30"
      ]} />
      <span :if={@credential.last_synced_at} class="text-base-content/60">
        Last synced: {format_relative_time(@credential.last_synced_at)}
      </span>
      <span :if={!@credential.last_synced_at} class="text-base-content/60">
        Never synced
      </span>
    </div>
    """
  end

  defp format_memory(mb) when mb >= 1024, do: "#{div(mb, 1024)} GB RAM"
  defp format_memory(mb), do: "#{mb} MB RAM"

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end
end
