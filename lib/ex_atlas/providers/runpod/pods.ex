defmodule ExAtlas.Providers.RunPod.Pods do
  @moduledoc """
  Thin wrappers over Runpod's REST v2 `/pods` endpoints. Each function returns
  `{:ok, body} | {:error, ExAtlas.Error.t()}`.

  Translation between `ExAtlas.Spec.ComputeRequest` and RunPod's native payload
  lives in `ExAtlas.Providers.RunPod.Translate`.
  """

  alias ExAtlas.Providers.HTTP
  alias ExAtlas.Providers.RunPod.Client

  @doc """
  POST /pods — create a pod. `body` is already in Runpod's native shape.

  Retried on a 429 only (`ExAtlas.Providers.HTTP.retry_rate_limited/2`): a
  create that timed out or answered 5xx may still have made a pod, and a retry
  would rent a second one that nothing tracks.
  """
  def create(ctx, body) do
    ctx
    |> Client.management()
    |> Req.post(url: "/pods", json: body, retry: &HTTP.retry_rate_limited/2)
    |> Client.handle_response(201)
  end

  @doc "GET /pods/:id — fetch a pod."
  def get(ctx, id) do
    ctx |> Client.management() |> Req.get(url: "/pods/#{encode(id)}") |> Client.handle_response()
  end

  @doc """
  GET /pods — every pod on the account, following `pagination.nextCursor`.

  Returns `{:ok, [pod]}`. A failed page, a page that is not a list of pod
  objects, or a cursor that does not advance fails the whole call: a partial
  list would show a live pod as missing.
  """
  def list(ctx), do: Client.list_all(ctx, "/pods", "pods")

  @doc "POST /pods/:id/action `stop` — stop a pod (keeps its disk)."
  def stop(ctx, id), do: action(ctx, id, "stop")

  @doc "POST /pods/:id/action `start` — resume a stopped pod."
  def start(ctx, id), do: action(ctx, id, "start")

  defp action(ctx, id, action) do
    ctx
    |> Client.management()
    |> Req.post(url: "/pods/#{encode(id)}/action", json: %{action: action})
    |> Client.handle_response()
  end

  @doc "DELETE /pods/:id — terminate a pod."
  def delete(ctx, id) do
    ctx
    |> Client.management()
    |> Req.delete(url: "/pods/#{encode(id)}")
    |> Client.handle_response(200..204)
  end

  # A pod id can come from a tracking record whoever wrote the store chose, so
  # it is one path segment, never more (issue 138).
  defp encode(id), do: URI.encode(to_string(id), &URI.char_unreserved?/1)
end
