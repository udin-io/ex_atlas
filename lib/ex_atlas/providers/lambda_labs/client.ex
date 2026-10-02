defmodule ExAtlas.Providers.LambdaLabs.Client do
  @moduledoc """
  The `Req` client for Lambda's Cloud API v1, `https://cloud.lambda.ai/api/v1`.

  Every success body wraps its result in `data`; these functions return what
  `data` holds. A request emits `[:ex_atlas, :lambda_labs, :request]`
  telemetry.
  """

  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Secret

  @base_url "https://cloud.lambda.ai/api/v1"
  @telemetry_prefix [:ex_atlas, :lambda_labs]

  # 100 is the largest `page_size` Lambda accepts. The page cap stops a token
  # that never ends from looping forever.
  @page_size 100
  @max_pages 100

  @doc "Base URL of the Cloud API."
  def base_url, do: @base_url

  # The Reaper lists with no per-call `base_url`, so a proxy or a test server
  # set here is the only one it reaches.
  defp configured_base_url,
    do: Application.get_env(:ex_atlas, :lambda_labs, [])[:base_url]

  @doc """
  A Req client with the Bearer key, JSON headers, `retry: :safe_transient`
  (a `GET` only) and a 30 s receive timeout. The base URL is `ctx.base_url`,
  else `config :ex_atlas, :lambda_labs, base_url:`, else Lambda's.
  `ctx.req_options` win.
  """
  @spec api(ExAtlas.Provider.ctx()) :: Req.Request.t()
  def api(ctx) do
    Req.new(
      base_url: Map.get(ctx, :base_url) || configured_base_url() || @base_url,
      auth: bearer(ctx),
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}],
      retry: :safe_transient,
      max_retries: 3,
      receive_timeout: 30_000
    )
    |> HTTP.attach_telemetry(@telemetry_prefix, :cloud)
    |> HTTP.merge_user_options(ctx)
  end

  @doc "GET `path` and return its `data`."
  @spec get(ExAtlas.Provider.ctx(), String.t()) :: {:ok, term()} | {:error, ExAtlas.Error.t()}
  def get(ctx, path) do
    ctx |> api() |> Req.get(url: path) |> handle(path)
  end

  @doc """
  POST `body` to `path` and return its `data`.

  A value in `body` may be an `ExAtlas.Secret`. It is revealed in the last
  request step, as Req encodes the body, so no `Req.Request` field holds it
  before then. `opts` go to `Req.post/2` (`retry:`).
  """
  @spec post(ExAtlas.Provider.ctx(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, ExAtlas.Error.t()}
  def post(ctx, path, body, opts \\ []) do
    ctx
    |> api()
    |> Req.Request.append_request_steps(
      atlas_sealed_json: fn request ->
        %{request | body: Jason.encode_to_iodata!(reveal(body))}
      end
    )
    |> Req.post([url: path] ++ opts)
    |> handle(path)
  end

  @doc """
  GET `path`, following `page_token` until Lambda returns none.

  Returns `{:ok, [entry]}`. A failed page, a page whose `data` is not a list
  of objects, or a token that does not advance fails the whole call: a
  partial list would show a live instance as missing.
  """
  @spec list_all(ExAtlas.Provider.ctx(), String.t()) ::
          {:ok, [map()]} | {:error, ExAtlas.Error.t()}
  def list_all(ctx, path), do: list_pages(ctx, path, nil, [], 0)

  defp list_pages(_ctx, path, _token, _acc, @max_pages),
    do: error("GET #{path} returned more than #{@max_pages} pages")

  defp list_pages(ctx, path, token, acc, page) do
    params =
      if token, do: [page_size: @page_size, page_token: token], else: [page_size: @page_size]

    result =
      ctx
      |> api()
      |> Req.get(url: path, params: params)
      |> HTTP.handle_response(200..299, :lambda_labs)

    with {:ok, body} <- result,
         {:ok, entries} <- page_entries(body, path) do
      case body["page_token"] do
        next when is_binary(next) and next != "" and next != token ->
          list_pages(ctx, path, next, [entries | acc], page + 1)

        next when is_binary(next) and next != "" ->
          error("GET #{path} pagination did not advance")

        _ ->
          {:ok, [entries | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  # `raw` never carries entry bodies: an instance holds its `jupyter_token`.
  defp page_entries(%{"data" => entries}, path) when is_list(entries) do
    if Enum.all?(entries, &is_map/1),
      do: {:ok, entries},
      else: error("GET #{path} listed an entry that is not an object")
  end

  defp page_entries(_body, path), do: error("unexpected body for GET #{path}")

  defp handle(result, path) do
    case HTTP.handle_response(result, 200..299, :lambda_labs) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, _other} -> error("unexpected body for #{path}")
      {:error, _} = err -> err
    end
  end

  defp reveal(body), do: Map.new(body, fn {key, value} -> {key, Secret.reveal(value)} end)

  defp error(message),
    do: {:error, ExAtlas.Error.new(:provider, provider: :lambda_labs, message: message)}

  defp bearer(ctx) do
    HTTP.bearer(
      ctx,
      :lambda_labs,
      "no Lambda Labs API key configured. Pass `api_key:` per call, set " <>
        "`config :ex_atlas, :lambda_labs, api_key: \"...\"`, or set LAMBDA_LABS_API_KEY."
    )
  end
end
