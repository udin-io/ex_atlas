defmodule Atlas.Providers.Adapters.RunPod.Client do
  @moduledoc """
  HTTP client for the RunPod REST API.
  """

  @base_url "https://rest.runpod.io/v1"

  def new(api_token) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"authorization", "Bearer #{api_token}"}
      ]
    )
  end

  def list_pods(client) do
    Req.get(client, url: "/pods")
  end

  def get_pod(client, pod_id) do
    Req.get(client, url: "/pods/#{pod_id}")
  end

  def list_network_volumes(client) do
    Req.get(client, url: "/networkvolumes")
  end
end
