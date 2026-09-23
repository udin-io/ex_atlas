defmodule ExAtlas.Orchestrator.TrackingStore.MemoryConformanceTest do
  @moduledoc """
  Runs the shared TrackingStore conformance suite against the in-memory test
  store, so the behaviour is proven by two independent implementations rather
  than by DETS alone.
  """

  use ExUnit.Case, async: false

  use ExAtlas.Orchestrator.TrackingStoreConformance,
    store: ExAtlas.Test.TrackingStore.Memory,
    setup: {__MODULE__, :__start_memory__, []}

  @doc false
  def __start_memory__(_context) do
    ExUnit.Callbacks.start_supervised!(ExAtlas.Test.TrackingStore.Memory)
    :ok
  end
end
