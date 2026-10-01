defmodule ExAtlas.Providers.RunPod.NetworkVolumes do
  @moduledoc "Thin wrappers over RunPod's REST v2 `/network-volumes`."

  alias ExAtlas.Providers.RunPod.Client

  def create(ctx, body),
    do:
      ctx
      |> Client.management()
      |> Req.post(url: "/network-volumes", json: body)
      |> Client.handle_response(201)

  @doc """
  Returns the `networkVolumes` list, or a `:provider` error when the body has
  none or lists an entry that is not an object.
  """
  def list(ctx) do
    result =
      ctx |> Client.management() |> Req.get(url: "/network-volumes") |> Client.handle_response()

    with {:ok, body} <- result, do: volume_entries(body)
  end

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

  defp volume_entries(%{"networkVolumes" => volumes}) when is_list(volumes) do
    if Enum.all?(volumes, &is_map/1),
      do: {:ok, volumes},
      else: bad_body("GET /network-volumes listed an entry that is not an object")
  end

  defp volume_entries(_body), do: bad_body("unexpected body for GET /network-volumes")

  defp bad_body(message),
    do: {:error, ExAtlas.Error.new(:provider, provider: :runpod, message: message)}
end
