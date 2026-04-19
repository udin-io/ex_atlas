defmodule Atlas.Config do
  @moduledoc """
  Resolves which provider and which API key a call should use.

  ## Resolution order

  For the provider:

    1. `opts[:provider]` if present.
    2. `Application.get_env(:atlas, :default_provider)`.
    3. Raises `ArgumentError`.

  For the API key (per provider):

    1. `opts[:api_key]` if present.
    2. `Application.get_env(:atlas, provider)[:api_key]`.
    3. Environment variable (e.g. `RUNPOD_API_KEY`, `LAMBDA_LABS_API_KEY`).
    4. `nil` (providers decide whether to raise).

  This mirrors the `stripity_stripe` / `ex_aws` pattern: per-call overrides win,
  application config is the default, no global mutable state. Multi-tenant hosts
  pass `api_key:` per request and skip config entirely.

  ## Configuring the default provider

      # config/config.exs
      config :atlas,
        default_provider: :runpod,
        start_orchestrator: false

      config :atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")
      config :atlas, :lambda_labs, api_key: System.get_env("LAMBDA_LABS_API_KEY")
  """

  @builtin_providers %{
    runpod: Atlas.Providers.RunPod,
    fly: Atlas.Providers.Fly,
    lambda_labs: Atlas.Providers.LambdaLabs,
    vast: Atlas.Providers.Vast,
    mock: Atlas.Providers.Mock
  }

  @env_vars %{
    runpod: "RUNPOD_API_KEY",
    fly: "FLY_API_TOKEN",
    lambda_labs: "LAMBDA_LABS_API_KEY",
    vast: "VAST_API_KEY"
  }

  @type opts :: keyword()

  @doc "Pop `:provider` from opts and return `{provider_atom_or_module, remaining_opts}`."
  @spec pop_provider!(opts()) :: {atom() | module(), opts()}
  def pop_provider!(opts) do
    case Keyword.pop(opts, :provider) do
      {nil, rest} ->
        case Application.get_env(:atlas, :default_provider) do
          nil ->
            raise ArgumentError,
                  "no :provider passed and no :default_provider in application env. " <>
                    "Pass [provider: :runpod, ...] or set `config :atlas, default_provider: :runpod`."

          provider ->
            {provider, rest}
        end

      {provider, rest} ->
        {provider, rest}
    end
  end

  @doc """
  Build the ctx map passed to every provider callback.

  Resolves the API key and any Req overrides in one place.
  """
  @spec build_ctx(atom() | module(), opts()) :: Atlas.Provider.ctx()
  def build_ctx(provider, opts) do
    %{
      provider: provider,
      api_key: resolve_api_key(provider, opts),
      base_url: Keyword.get(opts, :base_url),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @doc "Resolve the module that implements `Atlas.Provider` for a given provider atom."
  @spec provider_module(atom() | module()) :: module()
  def provider_module(provider) when is_atom(provider) do
    case Map.get(@builtin_providers, provider) do
      nil ->
        if Code.ensure_loaded?(provider) and function_exported?(provider, :capabilities, 0) do
          provider
        else
          raise ArgumentError,
                "unknown provider: #{inspect(provider)}. " <>
                  "Known: #{@builtin_providers |> Map.keys() |> inspect()} or pass a module that " <>
                  "implements Atlas.Provider."
        end

      mod ->
        mod
    end
  end

  @doc "Map of built-in provider atoms to their implementing modules."
  @spec builtin_providers() :: %{atom() => module()}
  def builtin_providers, do: @builtin_providers

  @doc "Standard environment variable name for a provider's API key."
  @spec env_var(atom()) :: String.t() | nil
  def env_var(provider), do: Map.get(@env_vars, provider)

  defp resolve_api_key(provider, opts) do
    cond do
      key = Keyword.get(opts, :api_key) ->
        key

      key = app_config_key(provider) ->
        key

      env = @env_vars[provider] ->
        System.get_env(env)

      true ->
        nil
    end
  end

  defp app_config_key(provider) when is_atom(provider) do
    :atlas
    |> Application.get_env(provider, [])
    |> Keyword.get(:api_key)
  end
end
