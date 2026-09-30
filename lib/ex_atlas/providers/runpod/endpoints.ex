defmodule ExAtlas.Providers.RunPod.Endpoints do
  @moduledoc "Thin wrappers over RunPod's REST v2 `/serverless` endpoints."

  alias ExAtlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/serverless", json: body)
      |> Client.handle_response(201)

  def get(ctx, id),
    do:
      ctx |> Client.management() |> Req.get(url: "/serverless/#{id}") |> Client.handle_response()

  def list(ctx),
    do: ctx |> Client.management() |> Req.get(url: "/serverless") |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/serverless/#{id}")
      |> Client.handle_response(200..204)
end
