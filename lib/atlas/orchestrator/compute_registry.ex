defmodule Atlas.Orchestrator.ComputeRegistry do
  @moduledoc """
  `Registry` used by the orchestrator to look up `Atlas.Orchestrator.ComputeServer`
  processes by resource id.

  Registered key shape: `{:compute, resource_id}`.
  """
end
