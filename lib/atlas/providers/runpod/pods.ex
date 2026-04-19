defmodule Atlas.Providers.RunPod.Pods do
  @moduledoc """
  Thin wrappers over RunPod's REST `/pods` endpoints. Each function returns
  `{:ok, body} | {:error, Atlas.Error.t()}`.

  Translation between `Atlas.Spec.ComputeRequest` and RunPod's native payload
  lives in `Atlas.Providers.RunPod.Translate`.
  """

  alias Atlas.Providers.RunPod.Client

  @doc "POST /pods — create a pod. `body` is already in RunPod's native shape."
  def create(ctx, body) do
    ctx
    |> Client.management()
    |> Req.post(url: "/pods", json: body)
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

  @doc "POST /pods/:id/stop — stop a pod (keeps volume)."
  def stop(ctx, id) do
    ctx |> Client.management() |> Req.post(url: "/pods/#{id}/stop") |> Client.handle_response()
  end

  @doc "POST /pods/:id/start — resume a stopped pod."
  def start(ctx, id) do
    ctx |> Client.management() |> Req.post(url: "/pods/#{id}/start") |> Client.handle_response()
  end

  @doc "DELETE /pods/:id — terminate a pod."
  def delete(ctx, id) do
    ctx
    |> Client.management()
    |> Req.delete(url: "/pods/#{id}")
    |> Client.handle_response(200..204)
  end
end
