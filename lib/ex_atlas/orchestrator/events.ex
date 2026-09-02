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
    * `{:respawned, new_id}` — a preempted resource was replaced. Sent on the
      **old** id's topic so a subscriber can follow the session, then subscribe
      to `topic(new_id)`. It carries the id alone; the replacement's URL and
      bearer token come from `ExAtlas.Orchestrator.info/1`, which is already
      readable by the time the event is sent. Broadcasting the record would put
      a live credential on a PubSub topic.
    * `{:respawn_failed, {reason, error}}` — the replacement could not be
      spawned; the server is shutting down.
    * `{:progress, payload}` — a pod reported progress through
      `ExAtlas.Callback`. The payload is the container's own JSON object,
      relayed verbatim and retained nowhere; the convention is a `seq` plus
      whatever the job wants to say (`pct`, `step`, …).
    * `{:log, payload}` — a batch of log lines from the pod, by convention
      `%{"seq" => n, "lines" => [...]}`. **ExAtlas retains zero log bytes**:
      this is a bus, not a store, exactly as `ExAtlas.Fly.Logs.Streamer`
      already is for Fly log entries. A subscriber that wants history keeps it.
    * `{:task_report, %{exit_code: n}}` — the container declared its exit code
      before going away. Fires the moment the callback lands, so a subscriber
      learns the exit code without waiting for the resource to disappear. In
      `mode: :task` it also ends the task: either the usual disappearance
      confirms it, or a `:finish_grace_ms` timer does.
    * `{:task, outcome}` — a `mode: :task` session ended, and this is what
      happened: `:completed`, `:timed_out`, or `{:failed, reason}`. Sent
      *before* the `{:terminating, _}` / `{:status, :terminated}` pair, so a
      subscriber that ignores task events still sees a correct lifecycle.
      Without a `{:task_report, _}` first, `:completed` means the container
      ended and the resource is gone — not that the work succeeded. With one,
      it is proven: the container said `exit_code: 0`. A non-zero exit arrives
      as `{:task, {:failed, {:exit_code, n}}}`. See
      `ExAtlas.Orchestrator.run_task/1`.
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
