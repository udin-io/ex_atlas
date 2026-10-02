defmodule ExAtlas.Providers.Vast.Client do
  @moduledoc """
  The `Req` client for Vast.ai's REST API at `https://console.vast.ai`.

  Paths carry their version (`/api/v0/asks/1/`, `/api/v1/instances/`), since
  Vast serves one instance at v0 and the instance list at v1. A request emits
  `[:ex_atlas, :vast, :request]` telemetry.
  """

  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Secret

  @base_url "https://console.vast.ai"
  @telemetry_prefix [:ex_atlas, :vast]

  # 25 is the largest page `GET /api/v1/instances/` returns. The page cap
  # stops a token that never ends from looping forever.
  @page_size 25
  @max_pages 100

  @instances "/api/v1/instances/"
  @instances_params [limit: @page_size, order_by: ~s([{"col":"id","dir":"asc"}])]

  # Vast's server maximum for a charges page.
  @charges "/api/v0/charges/"
  @charges_page_size 500

  @doc "Base URL of the API."
  def base_url, do: @base_url

  @doc """
  A Req client with the Bearer key, JSON headers, `retry: :safe_transient`
  (a `GET` only) and a 30 s receive timeout. The base URL is `ctx.base_url`,
  else `config :ex_atlas, :vast, base_url:`, else Vast's. `ctx.req_options`
  win.
  """
  @spec api(ExAtlas.Provider.ctx()) :: Req.Request.t()
  def api(ctx) do
    Req.new(
      base_url: Map.get(ctx, :base_url) || @base_url,
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
  POST `body` to `path` and return the body. `opts` go to `Req.post/2`
  (`retry:`).
  """
  @spec post(ExAtlas.Provider.ctx(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, ExAtlas.Error.t()}
  def post(ctx, path, body, opts \\ []) do
    ctx |> api() |> Req.post([url: path, json: body] ++ opts) |> handle()
  end

  @doc """
  PUT `body` to `path` and return the body.

  A value in `body`, or in a map under one of its keys, may be an
  `ExAtlas.Secret`. It is revealed in the last request step, as Req encodes
  the body, so no `Req.Request` field holds it before then. `opts` go to
  `Req.put/2` (`retry:`).
  """
  @spec put(ExAtlas.Provider.ctx(), String.t(), map(), keyword()) ::
          {:ok, term()} | {:error, ExAtlas.Error.t()}
  def put(ctx, path, body, opts \\ []) do
    ctx
    |> api()
    |> Req.Request.append_request_steps(
      atlas_sealed_json: fn request ->
        %{request | body: Jason.encode_to_iodata!(reveal(body))}
      end
    )
    |> Req.put([url: path] ++ opts)
    |> handle()
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
  def list_instances(ctx) do
    list_pages(ctx, @instances, "instances", @instances_params, nil, [], 0)
  end

  @doc """
  The rows of `GET /api/v0/charges/` for `source` (`"instance-123"`), for the
  UTC days from `from_unix` to `to_unix`, following `next_token`.

  The call lists the whole account's contract rows, since Vast takes no
  instance filter, and keeps those whose `source` is `source`. A failed page,
  a page whose `results` is not a list of objects, or a token that does not
  advance fails the whole call: a partial bill would read as a smaller one.
  """
  @spec instance_charges(ExAtlas.Provider.ctx(), String.t(), integer(), integer()) ::
          {:ok, [map()]} | {:error, ExAtlas.Error.t()}
  def instance_charges(ctx, source, from_unix, to_unix) do
    filters = %{
      "day" => %{"gte" => from_unix, "lte" => to_unix},
      "type" => %{"in" => ["instance"]}
    }

    params = [
      select_filters: Jason.encode!(filters),
      format: "table",
      limit: @charges_page_size
    ]

    with {:ok, rows} <- list_pages(ctx, @charges, "results", params, nil, [], 0) do
      {:ok, Enum.filter(rows, &(&1["source"] == source))}
    end
  end

  defp list_pages(_ctx, path, _key, _params, _token, _acc, @max_pages),
    do: error("GET #{path} returned more than #{@max_pages} pages")

  defp list_pages(ctx, path, key, params, token, acc, page) do
    query = if token, do: params ++ [after_token: token], else: params
    result = ctx |> api() |> Req.get(url: path, params: query) |> handle()

    with {:ok, body} <- result,
         {:ok, entries} <- page_entries(body, path, key) do
      case Map.get(body, "next_token") do
        next when is_binary(next) and next != "" and next != token ->
          list_pages(ctx, path, key, params, next, [entries | acc], page + 1)

        next when is_binary(next) and next != "" ->
          error("GET #{path} pagination did not advance")

        _ ->
          {:ok, [entries | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  # `raw` never carries entry bodies: an instance holds its env values.
  defp page_entries(%{} = body, path, key) do
    case body do
      %{^key => entries} when is_list(entries) ->
        if Enum.all?(entries, &is_map/1),
          do: {:ok, entries},
          else: error("GET #{path} listed an entry that is not an object")

      _ ->
        error("unexpected body for GET #{path}")
    end
  end

  defp page_entries(_body, path, _key), do: error("unexpected body for GET #{path}")

  defp handle(result), do: HTTP.handle_response(result, 200..299, :vast)

  defp reveal(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {key, value} -> {key, reveal(value)} end)

  defp reveal(value), do: Secret.reveal(value)

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
