defmodule ExAtlas.Fly.Supervisor do
  @moduledoc """
  Top-level supervisor for the Fly platform-ops sub-tree.

  `ExAtlas.Application` boots this automatically when `:ex_atlas` starts and
  `config :ex_atlas, :fly, enabled: true` (the default). Hosts that want to
  embed ExAtlas under their own application tree — e.g. to delay its start,
  or because they've disabled the `:ex_atlas` OTP app via
  `included_applications` — can drop this module into their own supervisor
  instead:

      # In MyApp.Application.start/2
      children = [
        MyApp.Repo,
        MyAppWeb.Endpoint,
        ExAtlas.Fly.Supervisor
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  The set of children started is identical to what `ExAtlas.Application`
  starts for the Fly sub-tree:

    * the configured `ExAtlas.Fly.TokenStorage` implementation
    * `ExAtlas.Fly.Tokens.Supervisor` (Registry + ETSOwner + per-app
      AppServers + Task.Supervisor)
    * `ExAtlas.Fly.Logs.StreamerSupervisor`
    * `ExAtlas.Fly.Dispatcher` (when dispatcher mode is `:registry`)

  Options are read from `Application.get_env(:ex_atlas, :fly, [])` — so the
  host can configure Fly the normal way even when starting the tree
  manually.
  """

  use Supervisor

  alias ExAtlas.Fly.Dispatcher
  alias ExAtlas.Fly.Logs.StreamerSupervisor
  alias ExAtlas.Fly.Tokens

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(_opts) do
    children = fly_children()
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def fly_children do
    fly_config = Application.get_env(:ex_atlas, :fly, [])

    if Keyword.get(fly_config, :enabled, true) do
      storage_mod = Keyword.get(fly_config, :token_storage, ExAtlas.Fly.TokenStorage.Dets)

      [{storage_mod, fly_config}, Tokens.Supervisor, StreamerSupervisor] ++
        dispatcher_child()
    else
      []
    end
  end

  defp dispatcher_child do
    if Dispatcher.needs_registry?() do
      [Dispatcher]
    else
      []
    end
  end
end
