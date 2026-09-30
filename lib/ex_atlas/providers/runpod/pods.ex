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

  @doc "GET /pods — list pods with optional query params."
  def list(ctx, params \\ []) do
    ctx
    |> Client.management()
    |> Req.get(url: "/pods", params: params)
    |> Client.handle_response()
  end

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
