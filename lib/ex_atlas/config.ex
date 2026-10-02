defmodule ExAtlas.Config do
  @moduledoc """
  Resolves which provider and which API key a call should use.

  ## Resolution order

  For the provider:

    1. `opts[:provider]` if present.
    2. `Application.get_env(:ex_atlas, :default_provider)`.
    3. Raises `ArgumentError`.

  For the API key (per provider):

    1. `opts[:api_key]` if present.
    2. `Application.get_env(:ex_atlas, provider)[:api_key]`.
    3. Environment variable (e.g. `RUNPOD_API_KEY`, `LAMBDA_LABS_API_KEY`).
    4. `nil` (providers decide whether to raise).

  The ctx holds the key as an `ExAtlas.Secret`; a provider reads it with
  `ExAtlas.Secret.reveal/1` where its HTTP client needs it.

  This mirrors the `stripity_stripe` / `ex_aws` pattern: per-call overrides win,
  application config is the default, no global mutable state. Multi-tenant hosts
  pass `api_key:` per request and skip config entirely.

  ## Configuring the default provider

      # config/config.exs
      config :ex_atlas,
        default_provider: :runpod,
        start_orchestrator: false

      config :ex_atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")
      config :ex_atlas, :lambda_labs, api_key: System.get_env("LAMBDA_LABS_API_KEY")
  """

  alias ExAtlas.Secret

  @builtin_providers %{
    runpod: ExAtlas.Providers.RunPod,
    fly: ExAtlas.Providers.Fly,
    lambda_labs: ExAtlas.Providers.LambdaLabs,
    vast: ExAtlas.Providers.Vast,
    mock: ExAtlas.Providers.Mock
  }

  @env_vars %{
    runpod: "RUNPOD_API_KEY",
    fly: "FLY_API_TOKEN",
    lambda_labs: "LAMBDA_LABS_API_KEY",
    vast: "VAST_API_KEY"
  }

  # Options ExAtlas resolves itself; everything else is provider-specific and
  # passed through to the ctx verbatim.
  @resolved_opts [:provider, :api_key, :base_url, :req_options]

  # Req options that carry a credential: the `authorization` header, any
  # hand-rolled header, and AWS signing keys.
  @secret_req_options [:auth, :headers, :aws_sigv4]

  @type opts :: keyword()

  @doc """
  Wrap the credentials in `opts` in `ExAtlas.Secret`, so no stacktrace that
  carries `opts` prints them: `:api_key`, and the
  `#{inspect(@secret_req_options)}` entries of `:req_options`.

  `ExAtlas.Orchestrator.spawn/1` runs this before anything else reads its
  opts; `build_ctx/2` runs it for every provider call. An `:api_key` that is
  not a string or an `ExAtlas.Secret` of one, or a `:req_options` that is not
  a keyword list, is a `NimbleOptions.ValidationError` with `value: nil`, so
  no message prints it.
  """
  @spec seal_credentials(opts()) :: {:ok, opts()} | {:error, NimbleOptions.ValidationError.t()}
  def seal_credentials(opts) do
    with {:ok, opts} <- seal(opts, :api_key, &seal_api_key/1) do
      seal(opts, :req_options, &seal_req_options/1)
    end
  end

  @doc """
  `req_options` with its `#{inspect(@secret_req_options)}` entries unwrapped,
  for the HTTP client to read. A provider calls this where it builds the
  request, and nowhere else.
  """
  @spec reveal_req_options(keyword()) :: keyword()
  def reveal_req_options(req_options) do
    Enum.map(req_options, fn {key, value} -> {key, Secret.reveal(value)} end)
  end

  @doc "The `req_options` entries that can carry a credential."
  @spec secret_req_options() :: [atom()]
  def secret_req_options, do: @secret_req_options

  defp seal(opts, key, seal_fun) do
    case Keyword.fetch(opts, key) do
      :error ->
        {:ok, opts}

      {:ok, value} ->
        with {:ok, sealed} <- seal_fun.(value), do: {:ok, Keyword.put(opts, key, sealed)}
    end
  end

  defp seal_api_key(key) do
    secret = Secret.wrap(key)

    case Secret.reveal(secret) do
      value when is_binary(value) or is_nil(value) -> {:ok, secret}
      _other -> invalid(:api_key, "expected a string or an ExAtlas.Secret of one")
    end
  end

  defp seal_req_options(req_options) do
    if is_list(req_options) and Keyword.keyword?(req_options) do
      {:ok, Enum.map(req_options, &seal_req_option/1)}
    else
      invalid(:req_options, "expected a keyword list")
    end
  end

  defp seal_req_option({key, value}) when key in @secret_req_options,
    do: {key, Secret.wrap(value)}

  defp seal_req_option(pair), do: pair

  defp invalid(key, detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: key,
       value: nil,
       message: "invalid value for #{inspect(key)} option: #{detail}"
     }}
  end

  @doc "Pop `:provider` from opts and return `{provider_atom_or_module, remaining_opts}`."
  @spec pop_provider!(opts()) :: {atom() | module(), opts()}
  def pop_provider!(opts) do
    case Keyword.pop(opts, :provider) do
      {nil, rest} ->
        case Application.get_env(:ex_atlas, :default_provider) do
          nil ->
            raise ArgumentError,
                  "no :provider passed and no :default_provider in application env. " <>
                    "Pass [provider: :runpod, ...] or set `config :ex_atlas, default_provider: :runpod`."

          provider ->
            {provider, rest}
        end

      {provider, rest} ->
        {provider, rest}
    end
  end

  @doc """
  Build the ctx map passed to every provider callback.

  Resolves the API key and any Req overrides in one place. Every remaining
  option is passed through untouched so provider-specific options reach the
  provider — `ExAtlas.get_job/2` and friends take no request struct, so
  `endpoint:` can only travel to `ExAtlas.Providers.RunPod` through the ctx:

      ExAtlas.get_job("job-1", provider: :runpod, endpoint: "abc123")
      # => ctx is %{provider: :runpod, api_key: ..., endpoint: "abc123", ...}

  The keys ExAtlas resolves itself (`:provider`, `:api_key`, `:base_url`,
  `:req_options`) always win over the pass-through values.
  """
  @spec build_ctx(atom() | module(), opts()) :: ExAtlas.Provider.ctx()
  def build_ctx(provider, opts) do
    opts = ok!(seal_credentials(opts))
    # A key from app config or the environment gets the same check.
    api_key = ok!(provider |> resolve_api_key(opts) |> seal_api_key())

    opts
    |> Keyword.drop(@resolved_opts)
    # Storage credentials belong to the request alone; a tracker passes its
    # whole opts here on every poll and terminate.
    |> Keyword.delete(:s3)
    |> Map.new()
    |> Map.merge(%{
      provider: provider,
      api_key: api_key,
      base_url: Keyword.get(opts, :base_url),
      req_options: Keyword.get(opts, :req_options, [])
    })
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, error}), do: raise(error)

  @doc "Resolve the module that implements `ExAtlas.Provider` for a given provider atom."
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
                  "implements ExAtlas.Provider."
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
    :ex_atlas
    |> Application.get_env(provider, [])
    |> Keyword.get(:api_key)
  end
end
