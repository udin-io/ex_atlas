defmodule ExAtlas.Orchestrator.Supervisor do
  @moduledoc """
  The orchestrator's tree, for a host to start in its own supervision tree.

  `config :ex_atlas, start_orchestrator: true` starts the orchestrator inside
  ExAtlas's application, which boots before the host's. A tracking store that
  lives in the host's repo (`ExAtlas.Orchestrator.TrackingStore.Ecto`) cannot
  be read then, so the host starts this supervisor after its repo instead:

      # config/runtime.exs
      config :ex_atlas, start_orchestrator: false

      # lib/my_app/application.ex
      children = [MyApp.Repo, ExAtlas.Orchestrator.Supervisor, MyAppWeb.Endpoint]

  It starts the same children, in the same order, as `start_orchestrator: true`
  does (see `ExAtlas.Application`). Shutdown runs in reverse, so the trackers
  write their records while the repo is still up.

  Use one of the two. With `start_orchestrator: true` this supervisor refuses
  to start: a second tree would crash on the names the first one holds.
  """

  use Supervisor

  alias ExAtlas.Callback.Limiter

  alias ExAtlas.Orchestrator.{
    Adopter,
    ComputeRegistry,
    ComputeServer,
    ComputeSupervisor,
    Lease,
    Ownership,
    Reaper,
    TrackingStore
  }

  @doc """
  Start the tree, registered as `#{inspect(__MODULE__)}`.

  Raises `ArgumentError` when `start_orchestrator: true` already starts it.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    if Application.get_env(:ex_atlas, :start_orchestrator, false) do
      raise ArgumentError,
            "#{inspect(__MODULE__)} is in your supervision tree and " <>
              "`config :ex_atlas, start_orchestrator: true` is set, so ExAtlas " <>
              "starts the same tree itself. Keep one: set `start_orchestrator: false`, " <>
              "or remove #{inspect(__MODULE__)} from your children."
    end

    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(_opts), do: Supervisor.init(children(), strategy: :one_for_one)

  @doc """
  The orchestrator's children, in start order.

  The tracking store comes first, so it outlives the trackers that write to it
  from `terminate/2`. The Adopter comes last: it needs the store, the Registry
  and the DynamicSupervisor, and it signals the Reaper, which must already be
  registered. `ExAtlas.Orchestrator.Lease` follows it, only when the store
  implements leases, `:reap_owner` is set and valid, and the node signs
  records (it has a callback secret).
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()} | module()]
  def children do
    tracking_store_child() ++
      [
        {Registry, keys: :unique, name: ComputeRegistry},
        {Task.Supervisor, name: ComputeServer.task_supervisor_name()},
        {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one},
        Limiter
      ] ++ pubsub_child() ++ [Reaper] ++ adopter_child() ++ lease_child()
  end

  defp tracking_store_child do
    case TrackingStore.impl() do
      nil -> []
      store -> [{store, []}]
    end
  end

  defp adopter_child do
    case TrackingStore.impl() do
      nil -> []
      _store -> [Adopter]
    end
  end

  defp lease_child do
    with store when not is_nil(store) <- TrackingStore.impl(),
         true <- Lease.supported?(store),
         true <- TrackingStore.signs?(),
         {:ok, owner} when is_binary(owner) <- Ownership.owner() do
      [{Lease, store: store, owner: owner}]
    else
      _no_lease -> []
    end
  end

  defp pubsub_child do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      [{Phoenix.PubSub, name: ExAtlas.PubSub}]
    else
      []
    end
  end
end
