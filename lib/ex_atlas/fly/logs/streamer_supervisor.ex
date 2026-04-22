defmodule ExAtlas.Fly.Logs.StreamerSupervisor do
  @moduledoc """
  Supervises per-app Fly log `Streamer` processes.

  Combines a `Registry` (unique keys by `app_name`) and a `DynamicSupervisor`
  (one `Streamer` per tracked app) under a `:rest_for_one` supervisor: if the
  registry dies, the DynamicSupervisor restarts with it (children are addressed
  via the registry, so a stale registry would be useless); but if a streamer
  burns the DynamicSupervisor's restart budget, the registry survives so other
  apps' cursors are not lost.

  The DynamicSupervisor also gets a generous `max_restarts` so a single
  misbehaving streamer (bad token, network flap) does not tear down its peers.
  """

  use Supervisor

  alias ExAtlas.Fly.Logs.Streamer

  @registry ExAtlas.Fly.Logs.StreamerRegistry
  @dynamic_sup ExAtlas.Fly.Logs.StreamerDynamicSupervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor,
       name: @dynamic_sup, strategy: :one_for_one, max_restarts: 20, max_seconds: 60}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Start a Streamer for `app_name` if one isn't already running."
  def start_streamer(app_name, project_dir, opts \\ []) do
    if streamer_running?(app_name) do
      {:error, :already_running}
    else
      streamer_opts =
        Keyword.merge(opts,
          app_name: app_name,
          project_dir: project_dir,
          registry: @registry,
          dynamic_sup: @dynamic_sup
        )

      DynamicSupervisor.start_child(@dynamic_sup, {Streamer, streamer_opts})
    end
  end

  @doc "Stop the Streamer for `app_name`, if any."
  def stop_streamer(app_name) do
    case Registry.lookup(@registry, app_name) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(@dynamic_sup, pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Whether a Streamer is running for `app_name`."
  def streamer_running?(app_name) do
    Registry.lookup(@registry, app_name) != []
  end

  @doc "Pid of the Streamer for `app_name`, or `nil`."
  def streamer_pid(app_name) do
    case Registry.lookup(@registry, app_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  def registry_name, do: @registry

  @doc false
  def dynamic_supervisor_name, do: @dynamic_sup
end
