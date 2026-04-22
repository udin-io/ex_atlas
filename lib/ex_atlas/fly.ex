defmodule ExAtlas.Fly do
  @moduledoc """
  Fly.io platform operations for ExAtlas.

  This is the public facade for everything Fly-related in atlas. It deliberately
  covers *platform* operations (deploys, logs, token lifecycle) — for GPU
  compute, see `ExAtlas.spawn_compute/2` and the provider behaviour.

  ## Quick start

      # In config/config.exs (optional — defaults are sensible)
      config :ex_atlas, :fly,
        enabled: true,
        dispatcher: :registry,
        storage_path: "priv/ex_atlas_fly"

  ### Discover apps from `fly.toml`

      ExAtlas.Fly.discover_apps("/path/to/project")
      # => [{"my-api", "/path/to/project"}, {"my-web", "/path/to/project/web"}]

  ### Tail logs

      ExAtlas.Fly.subscribe_logs("my-api", "/path/to/project")

      # Then in your GenServer / LiveView:
      def handle_info({:ex_atlas_fly_logs, "my-api", entries}, state) do
        # entries is a list of ExAtlas.Fly.Logs.LogEntry
        ...
      end

  ### Deploy with streaming output

      ExAtlas.Fly.subscribe_deploy(ticket_id)
      ExAtlas.Fly.stream_deploy(project_path, "web", ticket_id)

      def handle_info({:ex_atlas_fly_deploy, ^ticket_id, line}, state) do
        ...
      end
  """

  alias ExAtlas.Fly.Dispatcher
  alias ExAtlas.Fly.Logs.{Streamer, StreamerSupervisor}

  @doc "See `ExAtlas.Fly.Deploy.discover_apps/2`."
  defdelegate discover_apps(project_path), to: ExAtlas.Fly.Deploy
  defdelegate discover_apps(project_path, opts), to: ExAtlas.Fly.Deploy

  @doc "See `ExAtlas.Fly.Deploy.deploy/2`."
  defdelegate deploy(project_path, fly_toml_dir), to: ExAtlas.Fly.Deploy

  @doc "See `ExAtlas.Fly.Deploy.stream_deploy/3`."
  defdelegate stream_deploy(project_path, fly_toml_dir, ticket_id), to: ExAtlas.Fly.Deploy

  @doc """
  Subscribe the calling pid to log events for `app_name`, starting a streamer
  if none is running.

  Returns `{:error, :no_streamer}` if the streamer supervisor tree is not
  running (e.g. the Fly sub-tree is disabled via
  `config :ex_atlas, :fly, enabled: false`).

  `project_dir` is optional — it is carried in the Streamer's state for
  introspection but not used in the log-fetching code path.

  ### Teardown

  When the Streamer for `app_name` stops (all subscribers gone, or
  `stop_streamer/1`), it sends a final
  `{:ex_atlas_fly_logs_stopped, app_name}` message on the same topic.
  Subscribers should match on that and call `unsubscribe_logs/1` to clean
  up — atlas cannot unsubscribe them from a framework-agnostic dispatcher.
  """
  @spec subscribe_logs(String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, :no_streamer}
  def subscribe_logs(app_name, project_dir \\ nil, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:project_dir, project_dir)
      |> Keyword.put_new(:registry, StreamerSupervisor.registry_name())
      |> Keyword.put_new(:dynamic_sup, StreamerSupervisor.dynamic_supervisor_name())

    Streamer.subscribe(app_name, opts)
  end

  @doc "Unsubscribe the calling pid from log events for `app_name`."
  @spec unsubscribe_logs(String.t()) :: :ok
  def unsubscribe_logs(app_name) do
    Dispatcher.unsubscribe("ex_atlas_fly_logs:#{app_name}")
  end

  @doc "Subscribe the calling pid to streamed deploy output for `ticket_id`."
  @spec subscribe_deploy(String.t()) :: :ok | {:error, term()}
  def subscribe_deploy(ticket_id) do
    Dispatcher.subscribe("ex_atlas_fly_deploy:#{ticket_id}")
  end

  @doc "Unsubscribe the calling pid from streamed deploy output for `ticket_id`."
  @spec unsubscribe_deploy(String.t()) :: :ok
  def unsubscribe_deploy(ticket_id) do
    Dispatcher.unsubscribe("ex_atlas_fly_deploy:#{ticket_id}")
  end

  @doc "See `ExAtlas.Fly.Logs.StreamerSupervisor.stop_streamer/1`."
  defdelegate stop_streamer(app_name), to: StreamerSupervisor

  @doc "See `ExAtlas.Fly.Logs.StreamerSupervisor.streamer_running?/1`."
  defdelegate streamer_running?(app_name), to: StreamerSupervisor
end
