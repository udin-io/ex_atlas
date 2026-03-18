defmodule Atlas.Providers.Adapters.Fly.Client do
  @moduledoc """
  HTTP client for the Fly.io Machines API.
  """

  @base_url "https://api.machines.dev/v1"

  def new(api_token) do
    Req.new(
      base_url: @base_url,
      headers: [
        {"authorization", "Bearer #{api_token}"}
      ]
    )
  end

  def list_apps(client, org_slug) do
    Req.get(client, url: "/apps", params: [org_slug: org_slug])
  end

  def list_machines(client, app_name) do
    Req.get(client, url: "/apps/#{app_name}/machines")
  end

  def list_volumes(client, app_name) do
    Req.get(client, url: "/apps/#{app_name}/volumes")
  end

  def get_app(client, app_name) do
    Req.get(client, url: "/apps/#{app_name}")
  end

  def start_machine(client, app_name, machine_id) do
    Req.post(client, url: "/apps/#{app_name}/machines/#{machine_id}/start")
  end

  def stop_machine(client, app_name, machine_id) do
    Req.post(client, url: "/apps/#{app_name}/machines/#{machine_id}/stop")
  end

  def get_machine(client, app_name, machine_id) do
    Req.get(client, url: "/apps/#{app_name}/machines/#{machine_id}")
  end
end
