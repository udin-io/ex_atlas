defmodule Atlas.Application do
  @moduledoc """
  Opt-in supervision tree for Atlas.

  By default Atlas starts no processes — the library is pure REST/GraphQL and
  needs none. Setting `config :atlas, start_orchestrator: true` boots:

    * `Registry` — `Atlas.Orchestrator.ComputeRegistry` for `:via` lookups.
    * `DynamicSupervisor` — `Atlas.Orchestrator.ComputeSupervisor` for one
      `ComputeServer` per tracked resource.
    * `Phoenix.PubSub` — `Atlas.PubSub` for state-change broadcasts (only
      started when `phoenix_pubsub` is in the host app's deps).
    * `Atlas.Orchestrator.Reaper` — periodic reconciler.
  """
  use Application

  alias Atlas.Orchestrator.{ComputeRegistry, ComputeSupervisor, Reaper}

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:atlas, :start_orchestrator, false) do
        base = [
          {Registry, keys: :unique, name: ComputeRegistry},
          {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one}
        ]

        base ++ pubsub_child() ++ [Reaper]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Atlas.Supervisor)
  end

  defp pubsub_child do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      [{Phoenix.PubSub, name: Atlas.PubSub}]
    else
      []
    end
  end
end
