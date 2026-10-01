defmodule ExAtlas.Providers.RunPod.Templates do
  @moduledoc "Thin wrappers over Runpod's REST v2 `/templates`."

  alias ExAtlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/templates", json: body)
      |> Client.handle_response(201)

  @doc "Every template on the account, following the cursor. Returns `{:ok, [template]}`."
  def list(ctx), do: Client.list_all(ctx, "/templates", "templates")

  def get(ctx, id),
    do: ctx |> Client.management() |> Req.get(url: "/templates/#{id}") |> Client.handle_response()

  def delete(ctx, id),
    do:
      ctx
      |> Client.management()
      |> Req.delete(url: "/templates/#{id}")
      |> Client.handle_response(200..204)
end
