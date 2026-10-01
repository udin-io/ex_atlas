defmodule ExAtlas.Providers.RunPod.Catalog do
  @moduledoc """
  Runpod's REST v2 `/catalog` endpoints. Each function returns
  `{:ok, body} | {:error, ExAtlas.Error.t()}`.
  """

  alias ExAtlas.Providers.RunPod.Client

  @doc """
  GET /catalog/gpus — every GPU type with pod availability for one cloud.

  `cloud` is `"SECURE"` or `"COMMUNITY"`. Runpod reports `availability` for one
  cloud per request, and requires `product` with `include=AVAILABILITY`.

  Returns `{:ok, [entry]}`. A body with no `"gpus"` list of maps is an error.
  """
  @spec list_gpus(ExAtlas.Provider.ctx(), String.t()) ::
          {:ok, [map()]} | {:error, ExAtlas.Error.t()}
  def list_gpus(ctx, cloud) when cloud in ["SECURE", "COMMUNITY"] do
    result =
      ctx
      |> Client.management()
      |> Req.get(
        url: "/catalog/gpus",
        params: [include: "AVAILABILITY", product: "POD", cloud: cloud]
      )
      |> Client.handle_response()

    with {:ok, body} <- result, do: gpu_entries(body)
  end

  defp gpu_entries(%{"gpus" => gpus}) when is_list(gpus) do
    if Enum.all?(gpus, &is_map/1),
      do: {:ok, gpus},
      else: bad_body("GET /catalog/gpus listed an entry that is not an object")
  end

  defp gpu_entries(_body), do: bad_body("unexpected body for GET /catalog/gpus")

  defp bad_body(message),
    do: {:error, ExAtlas.Error.new(:provider, provider: :runpod, message: message)}
end
