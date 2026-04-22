defmodule Atlas.Fly.Logs.StreamerSupervisor do
  @moduledoc """
  Supervises per-app Fly log `Streamer` processes.

  Combines a `Registry` (unique keys by `app_name`) and a `DynamicSupervisor`
  (one `Streamer` per tracked app) under a single `:one_for_all` supervisor —
  if the registry dies, the streamers restart with a fresh registry.
  """

  use Supervisor

  alias Atlas.Fly.Logs.Streamer

  @registry Atlas.Fly.Logs.StreamerRegistry
  @dynamic_sup Atlas.Fly.Logs.StreamerDynamicSupervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @dynamic_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_all)
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
