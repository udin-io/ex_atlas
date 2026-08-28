defmodule ExAtlas.Orchestrator.Events do
  @moduledoc """
  PubSub helpers for orchestrator state changes.

  Every `ExAtlas.Orchestrator.ComputeServer` broadcasts on the topic
  `"compute:<id>"` whenever the tracked resource's state changes. LiveViews
  and other consumers subscribe with:

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

  Messages are shaped as `{:atlas_compute, id, event}` where `event` is one of:

    * `{:status, status}` — the resource's state changed. Local lifecycle
      reports `:provisioning | :running | :terminated`; the upstream status
      poller adds what the provider says, including the causes of death
      `:stopped | :failed | :vanished | :preempted`.
    * `{:heartbeat, now}` — idle ttl ticked over.
    * `{:poll_failed, error}` — a status poll could not reach the provider (or
      could not make sense of the answer). The resource is *not* presumed dead;
      the poller backs off and tries again.
    * `{:respawned, compute}` — a preempted resource was replaced. Sent on the
      **old** id's topic, carrying the replacement, so a subscriber can follow
      the session to its new id, URL and token.
    * `{:respawn_failed, {reason, error}}` — the replacement could not be
      spawned; the server is shutting down.
    * `{:terminating, reason}` — server is shutting down.
    * `{:terminate_failed, error}` — the upstream `terminate` call errored.

  Statuses are ordinary state changes, not necessarily endings: a session that
  ends emits `{:terminating, _}` and a final `{:status, :terminated}`, so
  that pair — not any individual status — is the reliable "it's over" signal.

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
