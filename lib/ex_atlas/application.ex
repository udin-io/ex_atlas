defmodule ExAtlas.Application do
  @moduledoc """
  Supervision tree for ExAtlas.

  ExAtlas spins up two independent sub-trees, each gated by configuration:

    * **Orchestrator** (opt-in via `config :ex_atlas, start_orchestrator: true`) —
      boots a `Registry`, a `DynamicSupervisor`, optional `Phoenix.PubSub`,
      and the `Reaper` that periodically reconciles tracked compute resources.

    * **Fly platform ops** (default on, disable via
      `config :ex_atlas, :fly, enabled: false`) — boots the token storage, token
      server, log streamer supervisor, and (when the dispatcher mode is
      `:registry`) a registry for log/deploy subscribers. Consumers that only
      call `ExAtlas.Fly.Deploy.deploy/2` directly don't need any of this and can
      safely disable the tree.
  """
  use Application

  alias ExAtlas.Fly.Dispatcher
  alias ExAtlas.Fly.Logs.StreamerSupervisor
  alias ExAtlas.Fly.Tokens
  alias ExAtlas.Orchestrator.{ComputeRegistry, ComputeSupervisor, Reaper}

  @impl true
  def start(_type, _args) do
    children = orchestrator_children() ++ fly_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: ExAtlas.Supervisor)
  end

  defp orchestrator_children do
    if Application.get_env(:ex_atlas, :start_orchestrator, false) do
      base = [
        {Registry, keys: :unique, name: ComputeRegistry},
        {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one}
      ]

      base ++ pubsub_child() ++ [Reaper]
    else
      []
    end
  end

  defp fly_children do
    fly_config = Application.get_env(:ex_atlas, :fly, [])

    case Keyword.get(fly_config, :enabled, true) do
      false ->
        []

      _ ->
        storage_mod = Keyword.get(fly_config, :token_storage, ExAtlas.Fly.TokenStorage.Dets)

        [{storage_mod, fly_config}, Tokens.Supervisor, StreamerSupervisor] ++
          dispatcher_child()
    end
  end

  defp dispatcher_child do
    if Dispatcher.needs_registry?() do
      [Dispatcher]
    else
      []
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
