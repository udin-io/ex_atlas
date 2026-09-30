defmodule ExAtlas.Providers.RunPod.NetworkVolumes do
  @moduledoc "Thin wrappers over RunPod's REST v2 `/network-volumes`."

  alias ExAtlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/network-volumes", json: body)
      |> Client.handle_response(201)

  def list(ctx),
    do: ctx |> Client.management() |> Req.get(url: "/network-volumes") |> Client.handle_response()

  def get(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/network-volumes/#{id}")
      |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/network-volumes/#{id}")
      |> Client.handle_response(200..204)
end
