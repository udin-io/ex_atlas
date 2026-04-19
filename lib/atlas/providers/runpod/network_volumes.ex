defmodule Atlas.Providers.RunPod.NetworkVolumes do
  @moduledoc "Thin wrappers over RunPod's REST `/networkvolumes`."

  alias Atlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/networkvolumes", json: body)
      |> Client.handle_response(201)

  def list(ctx),
    do: ctx |> Client.management() |> Req.get(url: "/networkvolumes") |> Client.handle_response()

  def get(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/networkvolumes/#{id}")
      |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/networkvolumes/#{id}")
      |> Client.handle_response(200..204)
end
