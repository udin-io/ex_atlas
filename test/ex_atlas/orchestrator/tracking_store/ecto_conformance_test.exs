defmodule ExAtlas.Orchestrator.TrackingStore.EctoConformanceTest do
  @moduledoc """
  Runs the shared TrackingStore conformance suite against the Ecto store, on a
  SQLite database file of each test's own.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  use ExAtlas.Orchestrator.TrackingStoreConformance,
    store: ExAtlas.Orchestrator.TrackingStore.Ecto,
    setup: {__MODULE__, :__start_ecto__, []}

  @doc false
  def __start_ecto__(%{tmp_dir: dir}) do
    ExAtlas.Test.Repo.start!(dir)
    ExUnit.Callbacks.start_supervised!(ExAtlas.Orchestrator.TrackingStore.Ecto)
    :ok
  end
end
