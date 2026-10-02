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

  ## A record lost to another node

  A node can lose a record while it still tracks it: its renewal came late,
  its clock runs behind, or someone edited its lease row. On every
  successful renewal it reads the record of each pod it tracks, and stops
  each tracker whose record now names another owner. The tracker stops
  without deleting the pod or writing the record, even when it holds a
  finish report: both are the new owner's. Until that renewal, both nodes
  track the pod, for up to `lease_ttl_ms / 3` while the losing node can
  renew.

  ## Clocks

  Expiry is the renewing node's wall clock; a claimer compares it with its
  own. Keep clock skew between nodes well under `lease_ttl_ms`.
  """

  use GenServer

  require Logger

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, ComputeServer, TrackingStore}

  @default_ttl_ms 90_000
  # A dead node's tasks wait out the whole ttl before another node tracks them.
  @max_ttl_ms 3_600_000
  # Under about a database round trip, live nodes read each other's leases as
  # expired and take each other's tasks.
  @min_ttl_ms 1_000

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
      renewed_at: nil,
      held_since: nil,
      adopting: nil,
      skipped: MapSet.new()
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

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{adopting: ref} = state),
    do: {:noreply, %{state | adopting: nil}}

  def handle_info({:skipped, id, owner, why}, state) do
    if MapSet.member?(state.skipped, id) do
      {:noreply, state}
    else
      Logger.warning(
        "[ExAtlas.Orchestrator.Lease] not taking over #{inspect(id)} of owner #{inspect(owner)}, " <>
          "whose lease expired: #{why}. The pod runs untracked until its owner returns or " <>
          "you delete it."
      )

      {:noreply, %{state | skipped: MapSet.put(state.skipped, id)}}
    end
  end

  # A crash restarts the Lease with no record of how long it held its lease,
  # so it would wait a full ttl again before claiming.
  def handle_info(_unexpected, state), do: {:noreply, state}

  defp renew(state, now) do
    case safely(fn -> state.store.renew_lease(state.owner, now + state.ttl_ms) end) do
      :ok ->
        state = hold(state, now)
        safely(fn -> release_lost_trackers(state) end)
        if claiming?(state, now), do: claim(state, now), else: state

      other ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Lease] could not renew the lease of #{inspect(state.owner)} " <>
            "(#{inspect(other)}); claiming nothing until it renews."
        )

        state
    end
  end

  # One takeover at a time: records claimed while an adoption runs would
  # wait behind it anyway.
  defp claiming?(state, now),
    do: is_nil(state.adopting) and now - state.held_since >= state.ttl_ms

  defp claim(state, now) do
    lease = self()
    rewrite = &rewrite(&1, state.owner, lease)

    case safely(fn -> state.store.claim_expired(state.owner, now, rewrite) end) do
      {:ok, []} ->
        state

      {:ok, records} when is_list(records) ->
        Logger.info(
          "[ExAtlas.Orchestrator.Lease] took over #{length(records)} record(s) of expired " <>
            "owners: #{Enum.map_join(records, ", ", &inspect(&1.id))}"
        )

        adopt(state, records)

      other ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Lease] could not claim expired owners' records (#{inspect(other)})"
        )

        state
    end
  end

  # One provider call per record: in a task, so a slow provider never holds
  # back the next renewal.
  defp adopt(state, records) do
    %{owner: owner, store: store} = state

    {:ok, pid} =
      Task.Supervisor.start_child(ComputeServer.task_supervisor_name(), fn ->
        Adopter.adopt_claimed(records, owner, store)
      end)

    %{state | adopting: Process.monitor(pid)}
  end

  # Runs inside the store's claim, once per candidate record.
  defp rewrite(record, owner, lease) do
    case skip_reason(record) do
      nil ->
        {:ok, TrackingStore.rewrite(Map.put(record, :owner, owner), true)}

      why ->
        send(lease, {:skipped, Map.get(record, :id), Map.get(record, :owner), why})
        :skip
    end
  end

  defp skip_reason(record) do
    if TrackingStore.sealed?(record),
      do: Adopter.refusal(record),
      else: "its record is not signed by this node's key"
  end

  # `held_since` is the start of this node's unbroken run of renewals. A node
  # claims only once it has held its lease a full ttl: at boot, and after its
  # own lease lapsed (a database outage expires every lease at once), every
  # live node then renews before any of them claims.
  defp hold(%{renewed_at: at, ttl_ms: ttl} = state, now) when is_integer(at) and now - at < ttl,
    do: %{state | renewed_at: now}

  defp hold(state, now), do: %{state | renewed_at: now, held_since: now}

  # On every renewal, not only after a lapse this node's clock saw: skew, a
  # late write, a forged expiry or a claim before this node's first renewal
  # all lose records without one.
  defp release_lost_trackers(state) do
    for id <- Orchestrator.list_ids(),
        lost?(state, id),
        {:ok, pid} <- [Orchestrator.lookup(id)] do
      Logger.warning(
        "[ExAtlas.Orchestrator.Lease] another node now owns #{inspect(id)}; stopping " <>
          "#{inspect(state.owner)}'s tracker and leaving the pod to it."
      )

      ComputeServer.release(pid)
    end

    :ok
  end

  defp lost?(state, id) do
    case safely(fn -> state.store.get(id) end) do
      {:ok, %{owner: owner}} when is_binary(owner) -> owner != state.owner
      _missing_or_unreadable -> false
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

  defp ttl!(ttl) when is_integer(ttl) and ttl >= @min_ttl_ms and ttl <= @max_ttl_ms, do: ttl

  defp ttl!(_other) do
    raise ArgumentError,
          "config :ex_atlas, :orchestrator, lease_ttl_ms: must be an integer from #{@min_ttl_ms} to " <>
            "#{@max_ttl_ms} (milliseconds); the default is #{@default_ttl_ms}"
  end
end
