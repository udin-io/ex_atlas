defmodule ExAtlas.Providers.Vast.Client do
  @moduledoc """
  The `Req` client for Vast.ai's REST API at `https://console.vast.ai`.

  Paths carry their version (`/api/v0/asks/1/`, `/api/v1/instances/`), since
  Vast serves one instance at v0 and the instance list at v1. A request emits
  `[:ex_atlas, :vast, :request]` telemetry.
  """

  alias ExAtlas.Providers.HTTP

  @base_url "https://console.vast.ai"
  @telemetry_prefix [:ex_atlas, :vast]

  # 25 is the largest page `GET /api/v1/instances/` returns. The page cap
  # stops a token that never ends from looping forever.
  @page_size 25
  @max_pages 100

  @doc "Base URL of the API."
  def base_url, do: @base_url

  defp configured_base_url, do: Application.get_env(:ex_atlas, :vast, [])[:base_url]

  @doc """
  A Req client with the Bearer key, JSON headers, `retry: :safe_transient`
  (a `GET` only) and a 30 s receive timeout. The base URL is `ctx.base_url`,
  else `config :ex_atlas, :vast, base_url:`, else Vast's. `ctx.req_options`
  win.
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
    |> HTTP.attach_telemetry(@telemetry_prefix, :console)
    |> HTTP.merge_user_options(ctx)
  end

  @doc "GET `path` and return the body."
  @spec get(ExAtlas.Provider.ctx(), String.t()) :: {:ok, term()} | {:error, ExAtlas.Error.t()}
  def get(ctx, path) do
    ctx |> api() |> Req.get(url: path) |> handle()
  end

  @doc """
  DELETE `path` and return the body. Retried on a 429 only, which means Vast
  did nothing.
  """
  @spec delete(ExAtlas.Provider.ctx(), String.t()) :: {:ok, term()} | {:error, ExAtlas.Error.t()}
  def delete(ctx, path) do
    ctx
    |> api()
    |> Req.delete(url: path, retry: &HTTP.retry_rate_limited/2)
    |> handle()
  end

  @doc """
  Every instance on the account, from `GET /api/v1/instances/`, following
  `next_token` until Vast returns none.

  A failed page, a page whose `instances` is not a list of objects, or a
  token that does not advance fails the whole call: a partial list would
  show a live instance as missing.
  """
  @spec list_instances(ExAtlas.Provider.ctx()) :: {:ok, [map()]} | {:error, ExAtlas.Error.t()}
  def list_instances(ctx), do: list_pages(ctx, nil, [], 0)

  @instances "/api/v1/instances/"

  defp list_pages(_ctx, _token, _acc, @max_pages),
    do: error("GET #{@instances} returned more than #{@max_pages} pages")

  defp list_pages(ctx, token, acc, page) do
    params =
      [limit: @page_size, order_by: ~s([{"col":"id","dir":"asc"}])] ++
        if(token, do: [after_token: token], else: [])

    result = ctx |> api() |> Req.get(url: @instances, params: params) |> handle()

    with {:ok, body} <- result,
         {:ok, entries} <- page_entries(body) do
      case Map.get(body, "next_token") do
        next when is_binary(next) and next != "" and next != token ->
          list_pages(ctx, next, [entries | acc], page + 1)

        next when is_binary(next) and next != "" ->
          error("GET #{@instances} pagination did not advance")

        _ ->
          {:ok, [entries | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  # `raw` never carries entry bodies: an instance holds its env values.
  defp page_entries(%{"instances" => entries}) when is_list(entries) do
    if Enum.all?(entries, &is_map/1),
      do: {:ok, entries},
      else: error("GET #{@instances} listed an entry that is not an object")
  end

  defp page_entries(_body), do: error("unexpected body for GET #{@instances}")

  defp handle(result), do: HTTP.handle_response(result, 200..299, :vast)

  defp error(message),
    do: {:error, ExAtlas.Error.new(:provider, provider: :vast, message: message)}

  defp bearer(ctx) do
    HTTP.bearer(
      ctx,
      :vast,
      "no Vast.ai API key configured. Pass `api_key:` per call, set " <>
        "`config :ex_atlas, :vast, api_key: \"...\"`, or set VAST_API_KEY."
    )
  end
end
