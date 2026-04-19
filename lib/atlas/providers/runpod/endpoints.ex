defmodule Atlas.Providers.RunPod.Endpoints do
  @moduledoc "Thin wrappers over RunPod's REST `/endpoints` (serverless)."

  alias Atlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/endpoints", json: body)
      |> Client.handle_response(201)

  def get(ctx, id),
    do: ctx |> Client.management() |> Req.get(url: "/endpoints/#{id}") |> Client.handle_response()

  def list(ctx),
    do: ctx |> Client.management() |> Req.get(url: "/endpoints") |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/endpoints/#{id}")
      |> Client.handle_response(200..204)
end
