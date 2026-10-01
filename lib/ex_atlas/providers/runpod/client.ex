defmodule ExAtlas.Providers.RunPod.Client do
  @moduledoc """
  Shared `Req` client factories for RunPod's two APIs:

    * REST management — `https://api.runpod.io/v2` — pods, serverless
      endpoints, templates, network volumes, billing.
    * Serverless runtime — `https://api.runpod.ai/v2/<endpoint>` — job submission,
      status polling, streaming.

  Each factory returns a `Req.Request.t()` pre-configured with authentication,
  JSON codec, retry policy, and telemetry. Consumers compose further via
  `Req.merge/2` or pass extra options per call.
  """

  @management_url "https://api.runpod.io/v2"
  @runtime_url "https://api.runpod.ai/v2"

  @telemetry_prefix [:ex_atlas, :runpod]

  @doc "Base URL for the REST management API."
  def management_url, do: @management_url

  @doc "Base URL for the serverless runtime API."
  def runtime_url, do: @runtime_url

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

  # 1000 entries a page, RunPod's maximum. The page cap stops a cursor that
  # never ends from looping forever.
  @page_size 1000
  @max_pages 100

  @doc """
  GET `path`, following `pagination.nextCursor` until RunPod has no next page.
  `key` names the list in each page body (`"pods"`, `"templates"`).

  Returns `{:ok, [entry]}`. A failed page, a page whose `key` is not a list of
  objects, or a cursor that does not advance fails the whole call: a partial
  list would show a live resource as missing.
  """
  @spec list_all(ExAtlas.Provider.ctx(), String.t(), String.t()) ::
          {:ok, [map()]} | {:error, ExAtlas.Error.t()}
  def list_all(ctx, path, key), do: list_pages(ctx, path, key, nil, [], 0)

  defp list_pages(_ctx, path, _key, _cursor, _acc, @max_pages),
    do: list_error("GET #{path} returned more than #{@max_pages} pages", nil)

  defp list_pages(ctx, path, key, cursor, acc, page) do
    params = if cursor, do: [limit: @page_size, cursor: cursor], else: [limit: @page_size]

    result =
      ctx
      |> management()
      |> Req.get(url: path, params: params)
      |> handle_response()

    with {:ok, body} <- result,
         {:ok, entries} <- page_entries(body, path, key) do
      case body["pagination"] do
        %{"hasNextPage" => true, "nextCursor" => next} when is_binary(next) and next != cursor ->
          list_pages(ctx, path, key, next, [entries | acc], page + 1)

        %{"hasNextPage" => true} ->
          list_error("GET #{path} pagination did not advance", body["pagination"])

        _ ->
          {:ok, [entries | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  defp page_entries(body, path, key) when is_map(body) do
    case Map.get(body, key) do
      entries when is_list(entries) ->
        if Enum.all?(entries, &is_map/1),
          do: {:ok, entries},
          else: list_error("GET #{path} listed an entry that is not an object", nil)

      _ ->
        list_error("unexpected body for GET #{path}", nil)
    end
  end

  # `raw` never carries entry bodies: pod and template `env` hold secrets.
  defp page_entries(_body, path, _key), do: list_error("unexpected body for GET #{path}", nil)

  defp list_error(message, raw),
    do: {:error, ExAtlas.Error.new(:provider, provider: :runpod, message: message, raw: raw)}

  defp status_in?(status, %Range{} = range), do: status in range
  defp status_in?(status, expected) when is_integer(expected), do: status == expected

  defp attach_telemetry(req, api) do
    Req.Request.append_response_steps(req, [
      {:atlas_telemetry,
       fn {request, response} ->
         :telemetry.execute(
           @telemetry_prefix ++ [:request],
           %{status: response.status},
           %{api: api, method: request.method, url: telemetry_url(request.url)}
         )

         {request, response}
       end}
    ])
  end

  # The query string carries request filters, so telemetry never logs it.
  defp telemetry_url(%URI{} = url), do: URI.to_string(%{url | query: nil})

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
