defmodule ExAtlas.Orchestrator.Lease do
  @moduledoc """
  Keeps this node's owner lease alive, and adopts the records of a node whose
  lease expired.

  Started by `ExAtlas.Orchestrator.Supervisor` when the tracking store exports
  `renew_lease/2` and `claim_expired/3` (`ExAtlas.Orchestrator.TrackingStore.Ecto`
  does), `:reap_owner` is set, and the node has a callback secret to verify
  records with. Every `lease_ttl_ms / 3` it:

    1. renews this node's lease until now plus `lease_ttl_ms`;
    2. if that renewal succeeded, releases its trackers of records another
       node now owns (below);
    3. if this node has held its lease without a gap for a full
       `lease_ttl_ms`, claims the records of every other owner whose lease
       expired, and adopts them in a task through
       `ExAtlas.Orchestrator.Adopter`, as a boot adopts its own.

  A node that cannot renew claims nothing: it may be the one cut off. A node
  that just booted, or whose own lease lapsed, waits a full ttl before it
  claims: after a database outage every lease reads expired, and by then
  every live node has renewed. `lease_ttl_ms` runs from 1 s to one hour.

      config :ex_atlas, :orchestrator,
        tracking_store: ExAtlas.Orchestrator.TrackingStore.Ecto,
        repo: MyApp.Repo,
        reap_owner: System.get_env("FLY_MACHINE_ID"),
        lease_ttl_ms: 90_000

  ## What it claims

  Only records this node's key verifies (`ExAtlas.Orchestrator.TrackingStore.sealed?/1`):
  a node that shares the callback secret signed them. An unsigned record of
  a dead owner is logged once and left: claimed, it could name any pod of the
  account, and the deadline would delete it. So is a signed record this
  build would not adopt (a newer version, say), and a row whose `owner`
  column no longer matches the record's signed `:owner`. An owner that never
  renewed a lease (a node on an older release) never expires.

  The Reaper deletes the pod and the record of the first two kinds once the
  owner is dead (`dead_owners/0`) and the pod's name carries that owner; the
  log line says so.

  ## A record lost to another node

  A node can lose a record while it still tracks it: its renewal came late,
  its clock runs behind, or someone edited its lease row. On every
  successful renewal it reads the record of each pod it tracks, and stops
  each tracker whose record now names another owner. The tracker stops
  without deleting the pod or writing the record, even when it holds a
  finish report: both are the new owner's. Until that renewal, both nodes
  track the pod: up to `lease_ttl_ms / 3` while the losing node can renew,
  and for as long as it cannot.

  ## Dead owners

  When the store exports `expired_leases/1` (the Ecto store does), each
  successful renewal also reads the expired leases and watches every owner
  with its expiry. It watches only a row this node's key signed
  (`ExAtlas.Orchestrator.TrackingStore.lease_signed?/3`): anyone who can
  write the lease table can insert a row, so an unsigned one, or one signed
  under another callback secret, is never dead. An owner whose expiry stays the same for
  `:reap_dead_owner_after_ms` on this node's monotonic clock is dead
  (`dead_owners/0`), and `ExAtlas.Orchestrator.Reaper` deletes its untracked
  pods unless `reap_dead_owners: false` is set.

      config :ex_atlas, :orchestrator, reap_dead_owner_after_ms: :timer.minutes(15)

  The window runs from two `lease_ttl_ms` to 24 hours. The default is 15
  minutes, or two ttls when that is longer. The watch starts again when an
  owner's expiry moves (it renewed), when this node fails to renew or to read
  the leases, and when a ttl passes between two of its renewals on either
  clock. A restarted Lease starts with no watch, so a node that just booted
  reads no owner as dead for a full window.

  ## Clocks

  Expiry is the renewing node's wall clock; a claimer compares it with its
  own. Keep clock skew between nodes well under `lease_ttl_ms`, and give
  every node the same `lease_ttl_ms`: a node with a longer ttl renews less
  often, and after a database outage another node can read it dead before
  its next renewal. The dead-owner
  window runs on the monotonic clock, so skew moves only when the watch
  starts, never how long it lasts.
  """

  use GenServer

  require Logger

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, ComputeServer, Ownership, Reaper, TrackingStore}

  @default_ttl_ms 90_000
  # A dead node's tasks wait out the whole ttl before another node tracks them.
  @max_ttl_ms 3_600_000
  # Under about a database round trip, live nodes read each other's leases as
  # expired and take each other's tasks.
  @min_ttl_ms 1_000

  @default_window_ms 900_000
  # An orphan of a dead owner bills for the whole window.
  @max_window_ms 86_400_000

  @dead_owners_timeout_ms 5_000

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Options: `:store` and `:owner` (required), `:ttl_ms` (default
  `config :ex_atlas, :orchestrator, lease_ttl_ms:`, else 90 s), and
  `:clock`, a 0-arity function returning wall-clock milliseconds, and
  `:monotonic`, one returning monotonic milliseconds.
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
    ttl = ttl!(Keyword.get_lazy(opts, :ttl_ms, &configured_ttl/0))

    state = %{
      store: Keyword.fetch!(opts, :store),
      owner: Keyword.fetch!(opts, :owner),
      ttl_ms: ttl,
      window_ms: window!(configured_window(ttl), ttl),
      clock: Keyword.get(opts, :clock, fn -> System.system_time(:millisecond) end),
      monotonic: Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end),
      renewed_at: nil,
      renewed_mono: nil,
      watch: %{},
      held_since: nil,
      adopting: nil,
      skipped: MapSet.new()
    }

    send(self(), :tick)
    {:ok, state}
  end

  @doc """
  The owners this node reads as dead, each with its lease's expiry in
  wall-clock ms: `%{"m1" => 1_790_000_000_000}`.

  An owner is dead when its lease has stayed expired, with the same expiry,
  for `:reap_dead_owner_after_ms` on this node's monotonic clock, while this
  node renewed its own lease every time, and a read at the call still finds
  that expiry. Answers `%{}` when no Lease runs, when the store has no
  `expired_leases/1`, and when this node's last renewal is a ttl old.
  """
  @spec dead_owners() :: %{optional(String.t()) => integer()}
  def dead_owners do
    GenServer.call(__MODULE__, :dead_owners, @dead_owners_timeout_ms)
  catch
    :exit, _not_running_or_slow -> %{}
  end

  @impl GenServer
  def handle_call(:dead_owners, _from, state) do
    {:reply, confirmed_dead(state, state.monotonic.()), state}
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
          "whose lease expired: #{why}. #{skipped_outcome(state, owner)}"
      )

      {:noreply, %{state | skipped: MapSet.put(state.skipped, id)}}
    end
  end

  # A crash restarts the Lease with no record of how long it held its lease,
  # so it would wait a full ttl again before claiming.
  def handle_info(_unexpected, state), do: {:noreply, state}

  # What happens to a skipped record's pod: the Reaper's record branch
  # (issue 145), or nothing.
  defp skipped_outcome(state, owner) do
    if Reaper.reap_dead_owners?() and function_exported?(state.store, :expired_leases, 1) and
         function_exported?(state.store, :delete_expired, 3) do
      "Unless #{inspect(owner)} renews, a Reaper whose :reap_providers covers the pod deletes " <>
        "the pod and this record once its " <>
        "signed lease has stayed expired for :reap_dead_owner_after_ms (#{state.window_ms} ms) " <>
        "and the pod's name carries that owner."
    else
      "The pod runs untracked until its owner returns or you delete it."
    end
  end

  defp renew(state, now) do
    case safely(fn -> state.store.renew_lease(state.owner, now + state.ttl_ms) end) do
      :ok ->
        held = hold(state, now)
        state = watch(held, now, held.held_since == state.held_since)
        release_lost_trackers(state)
        if claiming?(state, now), do: claim(state, now), else: state

      other ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Lease] could not renew the lease of #{inspect(state.owner)} " <>
            "(#{inspect(other)}); claiming nothing until it renews."
        )

        %{state | watch: %{}}
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
    case takeover_refusal(record) do
      nil ->
        {:ok, TrackingStore.rewrite(Map.put(record, :owner, owner), true)}

      why ->
        send(lease, {:skipped, Map.get(record, :id), Map.get(record, :owner), why})
        :skip
    end
  end

  @doc false
  # Why no node of this build takes `record` over from an expired owner, or
  # nil. The Reaper deletes the pod of a dead owner's record only when this
  # is non-nil: a record the Lease would claim is the Lease's (issue 145).
  @spec takeover_refusal(map()) :: String.t() | nil
  def takeover_refusal(record) do
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

  # Called after each renewal that succeeded. The watch holds each expired
  # owner with its expiry and the monotonic ms it was first seen with that
  # expiry. It starts again whenever this node's own hold may have broken:
  # `hold/2` restarted it (a ttl gap on the wall clock), or a ttl passed on
  # the monotonic clock since the last renewal.
  defp watch(state, now, hold_kept?) do
    mono = state.monotonic.()

    held? =
      hold_kept? and is_integer(state.renewed_mono) and mono - state.renewed_mono < state.ttl_ms

    watch = if held?, do: state.watch, else: %{}
    %{state | renewed_mono: mono, watch: observe(state, watch, now, mono)}
  end

  defp observe(state, watch, now, mono) do
    if function_exported?(state.store, :expired_leases, 1),
      do: observe_expired(signed_expired(state, now), watch, mono),
      else: %{}
  end

  defp observe_expired({:ok, expired}, watch, mono) do
    for {owner, at} <- expired,
        into: %{},
        do: {owner, {at, first_seen(watch, owner, at, mono)}}
  end

  defp observe_expired(other, _watch, _mono) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Lease] could not read expired leases (#{inspect(other)}); " <>
        "no owner reads as dead for a full :reap_dead_owner_after_ms after the next read."
    )

    %{}
  end

  # An expiry that moved is a renewal: its window starts again.
  defp first_seen(watch, owner, at, mono) do
    case watch do
      %{^owner => {^at, since}} -> since
      _new_or_moved -> mono
    end
  end

  # The watch is up to a third of a ttl old: an owner back from the dead may
  # have renewed since. Read the leases again and keep only an expiry that
  # has not moved.
  defp confirmed_dead(state, mono) do
    candidates =
      for {owner, {at, since}} <- state.watch,
          mono - since >= state.window_ms,
          into: %{},
          do: {owner, at}

    still_holding? = is_integer(state.renewed_mono) and mono - state.renewed_mono < state.ttl_ms

    with true <- still_holding? and candidates != %{},
         {:ok, expired} <- signed_expired(state, state.clock.()) do
      Map.filter(candidates, fn {owner, at} -> Map.get(expired, owner) == at end)
    else
      _nothing_to_confirm -> %{}
    end
  end

  # The expired owners a pod name can carry and whose row this node's key
  # signed: `%{owner => expires_at_ms}`. Anyone who can write the lease
  # table writes these rows, so an unsigned row is never dead (issue 148).
  defp signed_expired(state, now) do
    case safely(fn -> state.store.expired_leases(now) end) do
      {:ok, expired} when not is_map(expired) ->
        {:error, {:bad_shape, expired}}

      {:ok, expired} ->
        signed =
          for {owner, {at, mac}} <- expired,
              Ownership.valid?(owner),
              is_integer(at),
              TrackingStore.lease_signed?(owner, at, mac),
              into: %{},
              do: {owner, at}

        {:ok, signed}

      other ->
        other
    end
  end

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

  # Under two ttls, one late renewal of a live owner reads as death.
  defp configured_window(ttl) do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get_lazy(:reap_dead_owner_after_ms, fn -> max(@default_window_ms, 2 * ttl) end)
  end

  defp window!(window, ttl)
       when is_integer(window) and window >= 2 * ttl and window <= @max_window_ms,
       do: window

  defp window!(_other, ttl) do
    raise ArgumentError,
          "config :ex_atlas, :orchestrator, reap_dead_owner_after_ms: must be an integer from " <>
            "#{2 * ttl} to #{@max_window_ms} (milliseconds: two lease_ttl_ms to 24 hours); " <>
            "the default is #{max(@default_window_ms, 2 * ttl)}"
  end

  defp ttl!(ttl) when is_integer(ttl) and ttl >= @min_ttl_ms and ttl <= @max_ttl_ms, do: ttl

  defp ttl!(_other) do
    raise ArgumentError,
          "config :ex_atlas, :orchestrator, lease_ttl_ms: must be an integer from #{@min_ttl_ms} to " <>
            "#{@max_ttl_ms} (milliseconds); the default is #{@default_ttl_ms}"
  end
end
