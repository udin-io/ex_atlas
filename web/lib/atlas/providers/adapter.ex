defmodule Atlas.Providers.Adapter do
  @moduledoc """
  Behaviour for infrastructure provider adapters.

  Each provider (Fly.io, RunPod, etc.) implements this behaviour
  to normalize API interactions into a common interface.
  """

  @type credential :: Atlas.Providers.Credential.t()

  @callback test_connection(credential) :: :ok | {:error, term()}
  @callback list_apps(credential) :: {:ok, [map()]} | {:error, term()}
  @callback list_machines(credential, app_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_volumes(credential, app_id :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback list_storage_buckets(credential) :: {:ok, [map()]} | {:error, term()}
  @callback health_check(credential, machine_id :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback start_machine(credential, app_name :: String.t(), machine_id :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback stop_machine(credential, app_name :: String.t(), machine_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks [health_check: 2, start_machine: 3, stop_machine: 3]

  @adapters %{
    fly: Atlas.Providers.Adapters.Fly,
    runpod: Atlas.Providers.Adapters.RunPod
  }

  @doc "Returns the adapter module for a given provider type."
  @spec adapter_for(atom()) :: {:ok, module()} | {:error, :unknown_provider}
  def adapter_for(provider_type) do
    case Map.fetch(@adapters, provider_type) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_provider}
    end
  end
end
