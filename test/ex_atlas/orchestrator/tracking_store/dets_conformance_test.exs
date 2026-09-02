defmodule ExAtlas.Orchestrator.TrackingStore.DetsConformanceTest do
  @moduledoc """
  Runs the shared TrackingStore conformance suite against the DETS default.

  Each test gets its own `:tmp_dir` and its own store process, so the DETS
  table name — which is global to the node — is only ever open once.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  use ExAtlas.Orchestrator.TrackingStoreConformance,
    store: ExAtlas.Orchestrator.TrackingStore.Dets,
    setup: {__MODULE__, :__start_dets__, []}

  @doc false
  def __start_dets__(%{tmp_dir: dir}) do
    ExUnit.Callbacks.start_supervised!(
      {ExAtlas.Orchestrator.TrackingStore.Dets, storage_path: dir}
    )

    :ok
  end
end
