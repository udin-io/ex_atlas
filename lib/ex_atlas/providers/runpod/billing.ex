defmodule ExAtlas.Providers.RunPod.Billing do
  @moduledoc "Thin wrappers over RunPod's REST `/billing/*` endpoints."

  alias ExAtlas.Providers.RunPod.Client

  def pods(ctx, params \\ []),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/billing/pods", params: params)
      |> Client.handle_response()

  def endpoints(ctx, params \\ []),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/billing/serverless", params: params)
      |> Client.handle_response()

  def network_volumes(ctx, params \\ []),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/billing/network-volumes", params: params)
      |> Client.handle_response()
end
