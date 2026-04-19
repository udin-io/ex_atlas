defmodule Atlas.Providers.RunPod.Templates do
  @moduledoc "Thin wrappers over RunPod's REST `/templates`."

  alias Atlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/templates", json: body)
      |> Client.handle_response(201)

  def list(ctx),
    do: ctx |> Client.management() |> Req.get(url: "/templates") |> Client.handle_response()

  def get(ctx, id),
    do: ctx |> Client.management() |> Req.get(url: "/templates/#{id}") |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/templates/#{id}")
      |> Client.handle_response(200..204)
end
