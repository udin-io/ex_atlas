defmodule ExAtlas.Fly.Tokens.Supervisor do
  @moduledoc """
  Supervises the Fly-tokens trio: `Registry` + `ETSOwner` + `DynamicSupervisor`.

  Topology (`:rest_for_one`):

      ExAtlas.Fly.Tokens.Supervisor
      ├── Registry   (ExAtlas.Fly.Tokens.Registry)    ← keyed by app_name
      ├── ETSOwner   (ExAtlas.Fly.Tokens.ETSOwner)    ← owns the shared table
      └── DynamicSupervisor (ExAtlas.Fly.Tokens.DynamicSupervisor)
          ├── AppServer for "my-app"
          ├── AppServer for "other-app"
          └── ...

  Strategy rationale:

    * **Registry** crash: everything restarts. Children are registered there,
      so a stale registry would be useless anyway.
    * **ETSOwner** crash: `:rest_for_one` rebuilds the DynamicSupervisor too —
      every AppServer restarts, cache is empty, first call per app re-reads
      from storage. Clean blast-radius.
    * **AppServer** crash: stays scoped to that one app
      (DynamicSupervisor `:one_for_one`, `max_restarts: 20, max_seconds: 60`).

  ## Opts

  Production uses fixed module-level names for the three children. Tests
  override every name to isolate the trio per test; see
  `test/ex_atlas/fly/tokens/tokens_test.exs`.

    * `:name` — supervisor name (default `__MODULE__`).
    * `:registry` — Registry name (default `ExAtlas.Fly.Tokens.Registry`).
    * `:ets_owner` — ETSOwner name (default `ExAtlas.Fly.Tokens.ETSOwner`).
    * `:dynamic_sup` — DynamicSupervisor name
      (default `ExAtlas.Fly.Tokens.DynamicSupervisor`).
    * `:task_sup` — `Task.Supervisor` name used by AppServers to offload
      blocking persist writes (default `ExAtlas.Fly.Tokens.TaskSupervisor`).
    * `:ets_table` — ETS table name (default `:ex_atlas_fly_tokens`).
    * `:app_server_defaults` — keyword passed into every AppServer
      (`cmd_fn`, `config_file_fn`, `storage_mod`, `ttl_seconds`,
      `cli_timeout_ms`). Mostly for tests.
  """

  use Supervisor

  alias ExAtlas.Fly.Tokens.{AppServer, ETSOwner}

  @default_registry ExAtlas.Fly.Tokens.Registry
  @default_ets_owner ExAtlas.Fly.Tokens.ETSOwner
  @default_dynamic_sup ExAtlas.Fly.Tokens.DynamicSupervisor
  @default_task_sup ExAtlas.Fly.Tokens.TaskSupervisor
  @default_ets_table :ex_atlas_fly_tokens

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl Supervisor
  def init(opts) do
    registry = Keyword.get(opts, :registry, @default_registry)
    ets_owner = Keyword.get(opts, :ets_owner, @default_ets_owner)
    dynamic_sup = Keyword.get(opts, :dynamic_sup, @default_dynamic_sup)
    task_sup = Keyword.get(opts, :task_sup, @default_task_sup)
    ets_table = Keyword.get(opts, :ets_table, @default_ets_table)

    children = [
      {Registry, keys: :unique, name: registry},
      {ETSOwner, name: ets_owner, table_name: ets_table},
      {Task.Supervisor, name: task_sup},
      {DynamicSupervisor,
       name: dynamic_sup, strategy: :one_for_one, max_restarts: 20, max_seconds: 60}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Resolve the `AppServer` pid for `app_name`, starting one under the
  DynamicSupervisor if none exists.

  Handles the `{:error, {:already_started, pid}}` race where two processes
  both call `start_child` before either Registry.register call returns.
  """
  @spec resolve_app_server(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def resolve_app_server(app_name, opts \\ []) do
    registry = Keyword.get(opts, :registry, @default_registry)
    dynamic_sup = Keyword.get(opts, :dynamic_sup, @default_dynamic_sup)
    task_sup = Keyword.get(opts, :task_sup, @default_task_sup)
    ets_table = Keyword.get(opts, :ets_table, @default_ets_table)
    defaults = Keyword.get(opts, :app_server_defaults, [])

    case Registry.lookup(registry, app_name) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_opts =
          Keyword.merge(defaults,
            app_name: app_name,
            registry: registry,
            task_sup: task_sup,
            table_name: ets_table
          )

        case DynamicSupervisor.start_child(dynamic_sup, {AppServer, start_opts}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "Look up the AppServer pid for `app_name`, or `nil` if none is running."
  @spec whereis_app_server(String.t(), keyword()) :: pid() | nil
  def whereis_app_server(app_name, opts \\ []) do
    registry = Keyword.get(opts, :registry, @default_registry)

    case Registry.lookup(registry, app_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  def registry_name, do: @default_registry

  @doc false
  def dynamic_supervisor_name, do: @default_dynamic_sup

  @doc false
  def task_supervisor_name, do: @default_task_sup

  @doc false
  def ets_table_name, do: @default_ets_table
end
