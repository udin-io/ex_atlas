defmodule ExAtlas.Test.Orchestrator do
  @moduledoc """
  Starts the orchestrator supervision tree for a single test, the way
  `ExAtlas.Application` starts it in production, under the test supervisor so
  it is torn down again afterwards.
  """

  import ExUnit.Callbacks

  alias ExAtlas.Callback.Limiter
  alias ExAtlas.Orchestrator.{ComputeRegistry, ComputeServer, ComputeSupervisor}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.FaultyProvider

  # Long enough to key an HMAC, fixed so it is the same on every start! and
  # therefore safe to set from concurrently-starting test cases.
  @callback_secret "ex-atlas-test-callback-secret-0123456789"

  @doc "The callback signing secret `start!/0` configures."
  @spec callback_secret() :: String.t()
  def callback_secret, do: @callback_secret

  @doc "Boot the tree and point the default provider at the in-memory Mock."
  @spec start!() :: :ok
  def start! do
    Application.put_env(:ex_atlas, :start_orchestrator, true)
    Application.put_env(:ex_atlas, :default_provider, :mock)
    Application.put_env(:ex_atlas, :callback, secret: @callback_secret)
    Mock.reset()
    FaultyProvider.reset()

    start_supervised!({Registry, keys: :unique, name: ComputeRegistry})
    start_supervised!({Task.Supervisor, name: ComputeServer.task_supervisor_name()})
    start_supervised!({DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one})
    start_supervised!(Limiter)

    if Code.ensure_loaded?(Phoenix.PubSub) do
      start_supervised!({Phoenix.PubSub, name: ExAtlas.PubSub})
    end

    on_exit(fn ->
      FaultyProvider.reset()
      Application.delete_env(:ex_atlas, :start_orchestrator)
      Application.delete_env(:ex_atlas, :default_provider)
      Application.delete_env(:ex_atlas, :callback)
    end)

    :ok
  end
end
