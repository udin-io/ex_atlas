defmodule ExAtlas.Providers.RunPod.Pods do
  @moduledoc """
  Thin wrappers over Runpod's REST v2 `/pods` endpoints. Each function returns
  `{:ok, body} | {:error, ExAtlas.Error.t()}`.

  Translation between `ExAtlas.Spec.ComputeRequest` and RunPod's native payload
  lives in `ExAtlas.Providers.RunPod.Translate`.
  """

  alias ExAtlas.Providers.RunPod.Client

  @doc """
  POST /pods — create a pod. `body` is already in Runpod's native shape.

  Never retried: a create that timed out or answered 5xx may still have made a
  pod, and a retry would rent a second one that nothing tracks.
  """
  def create(ctx, body) do
    ctx
    |> Client.management()
    |> Req.post(url: "/pods", json: body, retry: false)
    |> Client.handle_response(201)
  end

  @doc "GET /pods/:id — fetch a pod."
  def get(ctx, id) do
    ctx |> Client.management() |> Req.get(url: "/pods/#{id}") |> Client.handle_response()
  end

  # 1000 pods a page, Runpod's maximum. The page cap stops a cursor that never
  # ends from looping forever.
  @page_size 1000
  @max_pages 100

  @doc """
  GET /pods — every pod on the account, following `pagination.nextCursor`.

  Returns `{:ok, [pod]}`. A failed page, a page that is not a list of pod
  objects, or a cursor that does not advance fails the whole call: a partial
  list would show a live pod as missing.
  """
  def list(ctx), do: list_pages(ctx, nil, [], 0)

  defp list_pages(_ctx, _cursor, _acc, @max_pages),
    do: list_error("GET /pods returned more than #{@max_pages} pages", nil)

  defp list_pages(ctx, cursor, acc, page) do
    params = if cursor, do: [limit: @page_size, cursor: cursor], else: [limit: @page_size]

    result =
      ctx
      |> Client.management()
      |> Req.get(url: "/pods", params: params)
      |> Client.handle_response()

    with {:ok, body} <- result,
         {:ok, pods} <- page_pods(body) do
      case body["pagination"] do
        %{"hasNextPage" => true, "nextCursor" => next} when is_binary(next) and next != cursor ->
          list_pages(ctx, next, [pods | acc], page + 1)

        %{"hasNextPage" => true} ->
          list_error("GET /pods pagination did not advance", body["pagination"])

        _ ->
          {:ok, [pods | acc] |> Enum.reverse() |> Enum.concat()}
      end
    end
  end

  defp page_pods(%{"pods" => pods}) when is_list(pods) do
    if Enum.all?(pods, &is_map/1),
      do: {:ok, pods},
      else: list_error("GET /pods listed an entry that is not a pod object", nil)
  end

  # `raw` never carries pod bodies: their `env` holds every pod's secrets.
  defp page_pods(_body), do: list_error("unexpected body for GET /pods", nil)

  defp list_error(message, raw),
    do: {:error, ExAtlas.Error.new(:provider, provider: :runpod, message: message, raw: raw)}

  @doc "POST /pods/:id/action `stop` — stop a pod (keeps its disk)."
  def stop(ctx, id), do: action(ctx, id, "stop")

  @doc "POST /pods/:id/action `start` — resume a stopped pod."
  def start(ctx, id), do: action(ctx, id, "start")

  defp action(ctx, id, action) do
    ctx
    |> Client.management()
    |> Req.post(url: "/pods/#{id}/action", json: %{action: action})
    |> Client.handle_response()
  end

  @doc "DELETE /pods/:id — terminate a pod."
  def delete(ctx, id) do
    ctx
    |> Client.management()
    |> Req.delete(url: "/pods/#{id}")
    |> Client.handle_response(200..204)
  end
end
