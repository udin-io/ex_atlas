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

    * **Fly platform ops** (default on, disable via
      `config :ex_atlas, :fly, enabled: false`) — boots the token storage, token
      server, log streamer supervisor, and (when the dispatcher mode is
      `:registry`) a registry for log/deploy subscribers. Consumers that only
      call `ExAtlas.Fly.Deploy.deploy/2` directly don't need any of this and can
      safely disable the tree.
  """
  use Application

  alias ExAtlas.Callback.Limiter

  alias ExAtlas.Orchestrator.{
    Adopter,
    ComputeRegistry,
    ComputeServer,
    ComputeSupervisor,
    Reaper,
    TrackingStore
  }

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
      base =
        tracking_store_child() ++
          [
            {Registry, keys: :unique, name: ComputeRegistry},
            {Task.Supervisor, name: ComputeServer.task_supervisor_name()},
            {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one},
            Limiter
          ]

      # The Adopter goes last: it needs the store, the Registry and the
      # DynamicSupervisor, and it signals the Reaper, which must therefore
      # already be registered. The Reaper starts gated, so ordering them this
      # way costs nothing and removes the only way the signal could be lost.
      base ++ pubsub_child() ++ [Reaper] ++ adopter_child()
    else
      []
    end
  end

  # First in the list, so that in a `:one_for_one` tree — where shutdown is the
  # reverse of startup — it is still there when the trackers run `terminate/2`
  # and delete their records on the way out.
  defp tracking_store_child do
    case TrackingStore.impl() do
      nil -> []
      store -> [{store, []}]
    end
  end

  defp adopter_child do
    case TrackingStore.impl() do
      nil -> []
      _store -> [Adopter]
    end
  end

  defp pubsub_child do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      [{Phoenix.PubSub, name: ExAtlas.PubSub}]
    else
      []
    end
  end
end
