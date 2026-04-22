defmodule ExAtlas.Providers.RunPod.Client do
  @moduledoc """
  Shared `Req` client factories for RunPod's three APIs:

    * REST management — `https://rest.runpod.io/v1` — pods, endpoints, templates,
      network volumes, container registry auth, billing.
    * Serverless runtime — `https://api.runpod.ai/v2/<endpoint>` — job submission,
      status polling, streaming.
    * Legacy GraphQL — `https://api.runpod.io/graphql` — GPU pricing catalog
      (not exposed in REST).

  Each factory returns a `Req.Request.t()` pre-configured with authentication,
  JSON codec, retry policy, and telemetry. Consumers compose further via
  `Req.merge/2` or pass extra options per call.
  """

  @management_url "https://rest.runpod.io/v1"
  @runtime_url "https://api.runpod.ai/v2"
  @graphql_url "https://api.runpod.io/graphql"

  @telemetry_prefix [:ex_atlas, :runpod]

  @doc "Base URL for the REST management API."
  def management_url, do: @management_url

  @doc "Base URL for the serverless runtime API."
  def runtime_url, do: @runtime_url

  @doc "GraphQL endpoint URL."
  def graphql_url, do: @graphql_url

  @doc """
  Build a Req client for the REST management API.

  Uses `Authorization: Bearer <key>`. Applies `:retry :transient` and a 30s
  receive timeout. Extra options in `ctx.req_options` are merged in last and
  win.
  """
  @spec management(ExAtlas.Provider.ctx()) :: Req.Request.t()
  def management(ctx) do
    api_key = fetch_key!(ctx)
    base = Map.get(ctx, :base_url) || @management_url

    Req.new(
      base_url: base,
      auth: {:bearer, api_key},
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      retry: :transient,
      max_retries: 3,
      receive_timeout: 30_000
    )
    |> attach_telemetry(:management)
    |> merge_user_options(ctx)
  end

  @doc """
  Build a Req client for the serverless runtime API, scoped to an endpoint id.

  Example: `runtime(ctx, "abc123")` talks to `https://api.runpod.ai/v2/abc123`.
  """
  @spec runtime(ExAtlas.Provider.ctx(), String.t()) :: Req.Request.t()
  def runtime(ctx, endpoint_id) do
    api_key = fetch_key!(ctx)

    Req.new(
      base_url: "#{@runtime_url}/#{endpoint_id}",
      auth: {:bearer, api_key},
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      retry: :transient,
      max_retries: 3,
      receive_timeout: 120_000
    )
    |> attach_telemetry(:runtime)
    |> merge_user_options(ctx)
  end

  @doc """
  Build a Req client for the legacy GraphQL API.

  GraphQL uses `?api_key=` as a query param, not a header.
  """
  @spec graphql(ExAtlas.Provider.ctx()) :: Req.Request.t()
  def graphql(ctx) do
    api_key = fetch_key!(ctx)

    Req.new(
      base_url: @graphql_url,
      params: [api_key: api_key],
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      retry: :transient,
      max_retries: 2,
      receive_timeout: 30_000
    )
    |> attach_telemetry(:graphql)
    |> merge_user_options(ctx)
  end

  @doc """
  Normalize a Req result into `{:ok, body} | {:error, ExAtlas.Error.t()}`.

  Accepts the `{:ok, %Req.Response{}} | {:error, exception}` returned by Req.
  """
  @spec handle_response({:ok, Req.Response.t()} | {:error, term()}, integer() | Range.t()) ::
          {:ok, term()} | {:error, ExAtlas.Error.t()}
  def handle_response(result, expected \\ 200..299)

  def handle_response({:ok, %Req.Response{status: status, body: body}}, expected) do
    if status_in?(status, expected) do
      {:ok, body}
    else
      {:error, ExAtlas.Error.from_response(status, body, :runpod)}
    end
  end

  def handle_response({:error, %{__exception__: true} = exception}, _expected) do
    {:error,
     ExAtlas.Error.new(:transport,
       provider: :runpod,
       message: Exception.message(exception),
       raw: exception
     )}
  end

  def handle_response({:error, other}, _expected) do
    {:error, ExAtlas.Error.new(:transport, provider: :runpod, raw: other)}
  end

  defp status_in?(status, %Range{} = range), do: status in range
  defp status_in?(status, expected) when is_integer(expected), do: status == expected

  defp attach_telemetry(req, api) do
    Req.Request.append_response_steps(req, [
      {:atlas_telemetry,
       fn {request, response} ->
         :telemetry.execute(
           @telemetry_prefix ++ [:request],
           %{status: response.status},
           %{api: api, method: request.method, url: URI.to_string(request.url)}
         )

         {request, response}
       end}
    ])
  end

  defp merge_user_options(req, %{req_options: opts}) when is_list(opts) and opts != [] do
    Req.merge(req, opts)
  end

  defp merge_user_options(req, _ctx), do: req

  defp fetch_key!(%{api_key: nil}) do
    raise ExAtlas.Error,
      kind: :unauthorized,
      provider: :runpod,
      message:
        "no RunPod API key configured. Pass `api_key:` per call, set " <>
          "`config :ex_atlas, :runpod, api_key: \"...\"`, or set RUNPOD_API_KEY."
  end

  defp fetch_key!(%{api_key: key}) when is_binary(key), do: key
end
