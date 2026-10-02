defmodule ExAtlas.Orchestrator.ComputeSupervisor do
  @moduledoc """
  `DynamicSupervisor` that parents one `ExAtlas.Orchestrator.ComputeServer` per
  tracked resource. Started by `config :ex_atlas, start_orchestrator: true`, or by
  `ExAtlas.Orchestrator.Supervisor` in the host's tree.
  """
end
