defmodule ExAtlas.Test.RemoteProvider do
  @moduledoc """
  An `ExAtlas.Provider` that forwards every callback to
  `ExAtlas.Providers.Mock` on another node with `:erpc`.

  The Mock keeps its pods in a node-local ETS table. A peer node that uses
  this provider therefore lists, spawns and terminates the same pods as the
  node named in `config :ex_atlas, :remote_provider_node`: two nodes, one
  provider account, which is the deployment issue #38 is about.
  """

  @behaviour ExAtlas.Provider

  alias ExAtlas.Providers.Mock

  @impl true
  def spawn_compute(req, ctx), do: forward(:spawn_compute, [req, ctx])

  @impl true
  def get_compute(id, ctx), do: forward(:get_compute, [id, ctx])

  @impl true
  def list_compute(filters, ctx), do: forward(:list_compute, [filters, ctx])

  @impl true
  def stop(id, ctx), do: forward(:stop, [id, ctx])

  @impl true
  def start(id, ctx), do: forward(:start, [id, ctx])

  @impl true
  def terminate(id, ctx), do: forward(:terminate, [id, ctx])

  @impl true
  def run_job(req, ctx), do: forward(:run_job, [req, ctx])

  @impl true
  def get_job(id, ctx), do: forward(:get_job, [id, ctx])

  @impl true
  def cancel_job(id, ctx), do: forward(:cancel_job, [id, ctx])

  @impl true
  def stream_job(id, ctx), do: forward(:stream_job, [id, ctx])

  @impl true
  def list_gpu_types(ctx), do: forward(:list_gpu_types, [ctx])

  @impl true
  def capabilities, do: Mock.capabilities()

  defp forward(fun, args) do
    home = Application.fetch_env!(:ex_atlas, :remote_provider_node)
    :erpc.call(home, Mock, fun, args)
  end
end
