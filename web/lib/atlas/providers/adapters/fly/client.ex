defmodule Atlas.Providers.Adapters.Fly.Client do
  @moduledoc """
  HTTP client for the Fly.io Machines API.

  Resolves tokens through `TokenCache` and automatically retries on 401
  responses by invalidating the cached token and re-fetching.
  """

  alias Atlas.Providers.Adapters.Fly.TokenCache
  alias Atlas.Providers.Credential

  defstruct [:token_source, :req, :cache_server]

  @type token_source :: :cli | {:credential, String.t()} | :static
  @type t :: %__MODULE__{
          token_source: token_source,
          req: Req.Request.t(),
          cache_server: GenServer.server() | nil
        }

  @base_url "https://api.machines.dev/v1"
  @graphql_url "https://api.fly.io/graphql"
  @default_cache TokenCache

  # --- Construction ---

  @doc """
  Creates a new client.

  ## Token sources

    * `new(:cli)` / `new(:cli, cache_server)` — CLI-detected token
    * `new(%Credential{}, cache_server)` — credential from DB
    * `new("token_string")` — static API token (no retry on 401)
  """
  def new(source, cache_server \\ @default_cache)

  def new(:cli, cache_server) do
    case TokenCache.get_cli_token(cache_server) do
      {:ok, token} ->
        {:ok, %__MODULE__{token_source: :cli, req: build_req(token), cache_server: cache_server}}

      :not_found ->
        {:error, :cli_token_not_found}
    end
  end

  def new(%Credential{id: id}, cache_server) do
    case TokenCache.get_token(id, cache_server) do
      {:ok, token} ->
        {:ok,
         %__MODULE__{
           token_source: {:credential, id},
           req: build_req(token),
           cache_server: cache_server
         }}

      {:error, _} = error ->
        error
    end
  end

  def new(%{api_token: api_token}, _cache_server) when is_binary(api_token) do
    new(api_token, nil)
  end

  def new(api_token, _cache_server) when is_binary(api_token) do
    {:ok, %__MODULE__{token_source: :static, req: build_req(api_token)}}
  end

  # --- Request Functions ---

  def list_apps(%__MODULE__{} = client, org_slug) do
    execute(client, fn req ->
      Req.get(req, url: "/apps", params: [org_slug: org_slug])
    end)
  end

  def list_machines(%__MODULE__{} = client, app_name) do
    execute(client, fn req ->
      Req.get(req, url: "/apps/#{app_name}/machines")
    end)
  end

  def list_volumes(%__MODULE__{} = client, app_name) do
    execute(client, fn req ->
      Req.get(req, url: "/apps/#{app_name}/volumes")
    end)
  end

  def get_app(%__MODULE__{} = client, app_name) do
    execute(client, fn req ->
      Req.get(req, url: "/apps/#{app_name}")
    end)
  end

  def start_machine(%__MODULE__{} = client, app_name, machine_id) do
    execute(client, fn req ->
      Req.post(req, url: "/apps/#{app_name}/machines/#{machine_id}/start")
    end)
  end

  def stop_machine(%__MODULE__{} = client, app_name, machine_id) do
    execute(client, fn req ->
      Req.post(req, url: "/apps/#{app_name}/machines/#{machine_id}/stop")
    end)
  end

  def get_machine(%__MODULE__{} = client, app_name, machine_id) do
    execute(client, fn req ->
      Req.get(req, url: "/apps/#{app_name}/machines/#{machine_id}")
    end)
  end

  @doc """
  Lists organizations accessible to the authenticated user via the Fly.io GraphQL API.

  Accepts optional `req_options` keyword list that gets merged into the request
  (useful for injecting test plugs).
  """
  def list_orgs(%__MODULE__{} = client, req_options \\ []) do
    query = "query { organizations { nodes { slug name type } } }"

    execute(client, fn req ->
      # Build a fresh Req because GraphQL URL differs from Machines API base_url,
      # but copy auth headers and any test plug options from the existing request.
      graphql_req =
        Req.new(
          headers: Map.to_list(req.headers),
          retry: false
        )
        |> Req.Request.merge_options(req.options |> Map.drop([:base_url]) |> Map.to_list())
        |> Req.Request.merge_options(req_options)

      Req.post(graphql_req, url: @graphql_url, json: %{query: query})
    end)
  end

  # --- 401 Retry Logic ---

  defp execute(%__MODULE__{} = client, request_fn) do
    case request_fn.(client.req) do
      {:ok, %{status: 401}} = original_response ->
        case refresh_token(client) do
          {:ok, refreshed_client} -> request_fn.(refreshed_client.req)
          :error -> original_response
        end

      other ->
        other
    end
  end

  defp refresh_token(%__MODULE__{token_source: :cli, cache_server: server} = client) do
    TokenCache.invalidate(:cli, server)

    case TokenCache.get_cli_token(server) do
      {:ok, token} ->
        {:ok, %{client | req: update_auth_header(client.req, token)}}

      :not_found ->
        :error
    end
  end

  defp refresh_token(%__MODULE__{token_source: {:credential, id}, cache_server: server} = client) do
    TokenCache.invalidate(id, server)

    case TokenCache.get_token(id, server) do
      {:ok, token} ->
        {:ok, %{client | req: update_auth_header(client.req, token)}}

      {:error, _} ->
        :error
    end
  end

  defp refresh_token(%__MODULE__{token_source: :static}), do: :error

  # --- Helpers ---

  defp build_req(token) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"authorization", "Bearer #{token}"}
      ],
      retry: false
    )
  end

  defp update_auth_header(req, token) do
    Req.Request.put_header(req, "authorization", "Bearer #{token}")
  end
end
