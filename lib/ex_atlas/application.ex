defmodule ExAtlas.Application do
  @moduledoc """
  Supervision tree for ExAtlas.

  ExAtlas spins up two independent sub-trees, each gated by configuration:

    * **Orchestrator** (opt-in via `config :ex_atlas, start_orchestrator: true`) —
      boots a `Registry`, a `Task.Supervisor` for the trackers' status polls,
      a `DynamicSupervisor`, the pod-callback rate limiter, optional
      `Phoenix.PubSub`, and the `Reaper` that periodically reconciles tracked
      compute resources. `ExAtlas.Callback` routes through the same `Registry`,
      so the inbound callback boundary needs this tree too.

      Unless `tracking_store: false`, it also boots an
      `ExAtlas.Orchestrator.TrackingStore` — first, so it outlives the trackers
      that write to it from `terminate/2` — and, last, the
      `ExAtlas.Orchestrator.Adopter` that re-adopts persisted compute at boot
      and releases the Reaper's gate.

      A host whose tracking store lives in its own repo starts the same tree
      itself, after the repo, with `ExAtlas.Orchestrator.Supervisor` and
      `start_orchestrator: false`.

    * **Fly platform ops** (default on, disable via
      `config :ex_atlas, :fly, enabled: false`) — boots the token storage, token
      server, log streamer supervisor, and (when the dispatcher mode is
      `:registry`) a registry for log/deploy subscribers. Consumers that only
      call `ExAtlas.Fly.Deploy.deploy/2` directly don't need any of this and can
      safely disable the tree.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = orchestrator_children() ++ ExAtlas.Fly.Supervisor.fly_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAtlas.Supervisor)
  end

  @doc """
  The orchestrator's children, in start order.

  Public so a test can start the real tree — ordering included — without
  restarting the application. Empty unless `start_orchestrator: true`.
  """
  @spec orchestrator_children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def orchestrator_children do
    if Application.get_env(:ex_atlas, :start_orchestrator, false) do
      ExAtlas.Orchestrator.Supervisor.children()
    else
      []
    end
  end
end
