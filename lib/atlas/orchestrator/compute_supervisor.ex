defmodule Atlas.Orchestrator.ComputeSupervisor do
  @moduledoc """
  `DynamicSupervisor` that parents one `Atlas.Orchestrator.ComputeServer` per
  tracked resource. Started automatically when `config :atlas, start_orchestrator: true`.
  """
end
