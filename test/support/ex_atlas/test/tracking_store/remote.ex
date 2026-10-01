defmodule ExAtlas.Test.TrackingStore.Remote do
  @moduledoc """
  An `ExAtlas.Orchestrator.TrackingStore` that forwards every callback to
  `ExAtlas.Test.TrackingStore.Memory` on the node named in
  `config :ex_atlas, :remote_provider_node`, with `:erpc`.

  A peer node that uses it shares one store with that node, the way two app
  nodes share one Postgres table.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  alias ExAtlas.Test.TrackingStore.Memory

  @impl true
  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc false
  def start_link, do: :ignore

  @impl true
  def put(record), do: forward(:put, [record])

  @impl true
  def get(id), do: forward(:get, [id])

  @impl true
  def delete(id), do: forward(:delete, [id])

  @impl true
  def all, do: forward(:all, [])

  defp forward(fun, args) do
    home = Application.fetch_env!(:ex_atlas, :remote_provider_node)
    :erpc.call(home, Memory, fun, args)
  end
end
