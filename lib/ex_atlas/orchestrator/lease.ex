defmodule ExAtlas.Orchestrator.Lease do
  @moduledoc """
  Keeps this node's owner lease alive, and adopts the records of a node whose
  lease expired.

  Started by `ExAtlas.Orchestrator.Supervisor` when the tracking store exports
  `renew_lease/2` and `claim_expired/3` (`ExAtlas.Orchestrator.TrackingStore.Ecto`
  does) and `:reap_owner` is set. Every `lease_ttl_ms / 3` it:

    1. renews this node's lease until now plus `lease_ttl_ms`;
    2. only if that renewal succeeded, claims the records of every other
       owner whose lease expired, and adopts them through
       `ExAtlas.Orchestrator.Adopter`, as a boot adopts its own.

  A node that cannot renew claims nothing: it may be the one cut off.

      config :ex_atlas, :orchestrator,
        tracking_store: ExAtlas.Orchestrator.TrackingStore.Ecto,
        repo: MyApp.Repo,
        reap_owner: System.get_env("FLY_MACHINE_ID"),
        lease_ttl_ms: 90_000

  ## What it claims

  Only records this node's key verifies (`ExAtlas.Orchestrator.TrackingStore.sealed?/1`):
  a node that shares the callback secret signed them. An unsigned record of
  a dead owner is logged once and left: claimed, it could name any pod of the
  account, and the deadline would delete it. An owner that never renewed a
  lease (a node on an older release) never expires.

  ## Clocks

  Expiry is the renewing node's wall clock; a claimer compares it with its
  own. Keep clock skew between nodes well under `lease_ttl_ms`.
  """

  use GenServer

  require Logger

  alias ExAtlas.Orchestrator.{Adopter, TrackingStore}

  @default_ttl_ms 90_000
  # A dead node's tasks wait out the whole ttl before another node tracks them.
  @max_ttl_ms 3_600_000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Options: `:store` and `:owner` (required), `:ttl_ms` (default
  `config :ex_atlas, :orchestrator, lease_ttl_ms:`, else 90 s), and
  `:clock`, a 0-arity function returning wall-clock milliseconds.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether `store` implements the lease callbacks."
  @spec supported?(module()) :: boolean()
  def supported?(store) do
    Code.ensure_loaded?(store) and function_exported?(store, :renew_lease, 2) and
      function_exported?(store, :claim_expired, 3)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      store: Keyword.fetch!(opts, :store),
      owner: Keyword.fetch!(opts, :owner),
      ttl_ms: ttl!(Keyword.get_lazy(opts, :ttl_ms, &configured_ttl/0)),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      unsigned: MapSet.new()
    }

    send(self(), :tick)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    now = state.clock.()
    state = renew(state, now)
    Process.send_after(self(), :tick, div(state.ttl_ms, 3))
    {:noreply, state}
  end

  def handle_info({:unsigned, id, owner}, state) do
    if MapSet.member?(state.unsigned, id) do
      {:noreply, state}
    else
      Logger.warning(
        "[ExAtlas.Orchestrator.Lease] not taking over #{inspect(id)} of owner #{inspect(owner)}, " <>
          "whose lease expired: its record is not signed by this node's key. The pod runs " <>
          "untracked until its owner returns or you delete it."
      )

      {:noreply, %{state | unsigned: MapSet.put(state.unsigned, id)}}
    end
  end

  defp renew(state, now) do
    case safely(fn -> state.store.renew_lease(state.owner, now + state.ttl_ms) end) do
      :ok ->
        claim(state, now)
        state

      other ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Lease] could not renew the lease of #{inspect(state.owner)} " <>
            "(#{inspect(other)}); claiming nothing until it renews."
        )

        state
    end
  end

  defp claim(state, now) do
    lease = self()
    rewrite = &rewrite(&1, state.owner, lease)

    case safely(fn -> state.store.claim_expired(state.owner, now, rewrite) end) do
      {:ok, []} ->
        :ok

      {:ok, records} ->
        Logger.info(
          "[ExAtlas.Orchestrator.Lease] took over #{length(records)} record(s) of expired " <>
            "owners: #{Enum.map_join(records, ", ", &inspect(&1.id))}"
        )

        Adopter.adopt_claimed(records, state.owner, state.store)

      other ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Lease] could not claim expired owners' records (#{inspect(other)})"
        )
    end
  end

  # Runs inside the store's claim, once per candidate record.
  defp rewrite(record, owner, lease) do
    if TrackingStore.sealed?(record) do
      {:ok, TrackingStore.rewrite(Map.put(record, :owner, owner), true)}
    else
      send(lease, {:unsigned, Map.get(record, :id), Map.get(record, :owner)})
      :skip
    end
  end

  # A store call that raises or exits must not take the lease down with it.
  defp safely(fun) do
    fun.()
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp configured_ttl do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:lease_ttl_ms, @default_ttl_ms)
  end

  defp ttl!(ttl) when is_integer(ttl) and ttl >= 3 and ttl <= @max_ttl_ms, do: ttl

  defp ttl!(_other) do
    raise ArgumentError,
          "config :ex_atlas, :orchestrator, lease_ttl_ms: must be an integer from 3 to " <>
            "#{@max_ttl_ms} (milliseconds); the default is #{@default_ttl_ms}"
  end
end
