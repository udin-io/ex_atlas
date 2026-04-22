defmodule ExAtlas.Orchestrator.ComputeSupervisor do
  @moduledoc """
  `DynamicSupervisor` that parents one `ExAtlas.Orchestrator.ComputeServer` per
  tracked resource. Started automatically when `config :ex_atlas, start_orchestrator: true`.
  """
end
