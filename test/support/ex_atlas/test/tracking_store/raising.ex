defmodule ExAtlas.Test.TrackingStore.Raising do
  @moduledoc false
  # Test-only tracking store whose `all/0` raises, simulating a host-supplied
  # store (a Repo, a Redis client) that blows up at boot rather than returning
  # an error tuple. Mirrors `ExAtlas.Fly.TokenStorage.Raising`.

  @behaviour ExAtlas.Orchestrator.TrackingStore

  @impl ExAtlas.Orchestrator.TrackingStore
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker}
  end

  def start_link, do: :ignore

  @impl ExAtlas.Orchestrator.TrackingStore
  def all, do: raise(RuntimeError, "simulated tracking store outage")

  @impl ExAtlas.Orchestrator.TrackingStore
  def get(_id), do: :error

  @impl ExAtlas.Orchestrator.TrackingStore
  def put(_record), do: :ok

  @impl ExAtlas.Orchestrator.TrackingStore
  def delete(_id), do: :ok
end
