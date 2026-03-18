defmodule AtlasWeb.MetricComponents do
  @moduledoc """
  Stat and metric display components.
  """
  use Phoenix.Component

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :description, :string, default: nil
  attr :class, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class={["stat", @class]}>
      <div class="stat-title">{@label}</div>
      <div class="stat-value text-2xl">{@value}</div>
      <div :if={@description} class="stat-desc">{@description}</div>
    </div>
    """
  end
end
