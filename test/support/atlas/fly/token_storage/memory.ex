defmodule Atlas.Fly.TokenStorage.Memory do
  @moduledoc """
  In-memory `Atlas.Fly.TokenStorage` implementation for tests.

  Backed by an `Agent` keyed by `{app_name, key}`. Data vanishes on process
  exit — perfect for isolated per-test state.

      setup do
        start_supervised!(Atlas.Fly.TokenStorage.Memory)
        :ok
      end
  """

  @behaviour Atlas.Fly.TokenStorage

  use Agent

  @impl Atlas.Fly.TokenStorage
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl Atlas.Fly.TokenStorage
  def get(app_name, key) do
    case Agent.get(__MODULE__, &Map.get(&1, {app_name, key})) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  @impl Atlas.Fly.TokenStorage
  def put(app_name, key, record) do
    Agent.update(__MODULE__, &Map.put(&1, {app_name, key}, record))
  end

  @impl Atlas.Fly.TokenStorage
  def delete(app_name, key) do
    Agent.update(__MODULE__, &Map.delete(&1, {app_name, key}))
  end
end
