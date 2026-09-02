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

  @doc """
  Boot the tree and point the default provider at the in-memory Mock.

  Options:

    * `:tracking_store` — `false` (the default, persistence off), a module, or
      `{module, start_opts}`. The store is configured *and* started under the
      test supervisor, so a test only has to say which one it wants.
  """
  @spec start!(keyword()) :: :ok
  def start!(opts \\ []) do
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
      Application.delete_env(:ex_atlas, :orchestrator)
    end)

    configure_store(Keyword.get(opts, :tracking_store, false))

    :ok
  end

  @doc """
  Merge `values` into `config :ex_atlas, :orchestrator`.

  The orchestrator config is one keyword list holding both the reaping knobs
  and `:tracking_store`, so a plain `put_env` from a test would silently drop
  whichever half it did not mention.
  """
  @spec put_env(keyword()) :: :ok
  def put_env(values) do
    current = Application.get_env(:ex_atlas, :orchestrator, [])
    Application.put_env(:ex_atlas, :orchestrator, Keyword.merge(current, values))
  end

  defp configure_store(false), do: put_env(tracking_store: false)

  defp configure_store({module, start_opts}) do
    put_env(tracking_store: module)
    start_supervised!({module, start_opts})
    :ok
  end

  defp configure_store(module) when is_atom(module), do: configure_store({module, []})
end
