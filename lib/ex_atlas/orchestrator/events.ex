defmodule ExAtlas.Orchestrator.Events do
  @moduledoc """
  PubSub helpers for orchestrator state changes.

  Every `ExAtlas.Orchestrator.ComputeServer` broadcasts on the topic
  `"compute:<id>"` whenever the tracked resource's state changes. LiveViews
  and other consumers subscribe with:

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

  Messages are shaped as `{:atlas_compute, id, event}` where `event` is one of:

    * `{:status, status}` — `:running | :stopped | :terminated | :failed`.
    * `{:heartbeat, now}` — idle ttl ticked over.
    * `{:terminating, reason}` — server is shutting down.

  If `phoenix_pubsub` is not available in the host app, broadcasts are silently
  skipped.
  """

  @pubsub ExAtlas.PubSub

  @spec topic(String.t()) :: String.t()
  def topic(id) when is_binary(id), do: "compute:" <> id

  @spec broadcast(String.t(), term()) :: :ok
  def broadcast(id, event) do
    if Code.ensure_loaded?(Phoenix.PubSub) and pubsub_alive?() do
      Phoenix.PubSub.broadcast(@pubsub, topic(id), {:atlas_compute, id, event})
    end

    :ok
  end

  defp pubsub_alive? do
    case Process.whereis(@pubsub) do
      nil -> false
      _pid -> true
    end
  end
end
