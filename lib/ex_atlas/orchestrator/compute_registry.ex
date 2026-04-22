defmodule ExAtlas.Orchestrator.ComputeRegistry do
  @moduledoc """
  `Registry` used by the orchestrator to look up `ExAtlas.Orchestrator.ComputeServer`
  processes by resource id.

  Registered key shape: `{:compute, resource_id}`.
  """
end
