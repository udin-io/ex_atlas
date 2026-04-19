defmodule Atlas.Providers.RunPod.Billing do
  @moduledoc "Thin wrappers over RunPod's REST `/billing/*` endpoints."

  alias Atlas.Providers.RunPod.Client

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
      |> Req.get(url: "/billing/endpoints", params: params)
      |> Client.handle_response()

  def network_volumes(ctx, params \\ []),
    do:
      ctx
      |> Client.management()
      |> Req.get(url: "/billing/networkvolumes", params: params)
      |> Client.handle_response()
end
