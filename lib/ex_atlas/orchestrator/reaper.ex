defmodule ExAtlas.Orchestrator.Reaper do
  @moduledoc """
  Periodic reconciliation GenServer.

  On each tick, the Reaper:

    1. Asks each tracked provider for its list of live resources.
    2. Compares against the `ComputeServer` processes in the Registry **and**
       the `ExAtlas.Orchestrator.TrackingStore`.
    3. Flags any resource that exists at the provider but appears in neither
       (symptom of a node restart after a crash) and, with a `:reap_owner`
       set, is named with this node's owner. It calls `ExAtlas.terminate/2`
       on each to reclaim the runaway spend. See "More than one node" for
       when it reaps nothing at all.

  Configuration:

      config :ex_atlas, :orchestrator,
        reap_interval_ms: 60_000,
        reap_providers: [:runpod],
        reap_name_prefix: "atlas-",
        reap_grace_ms: 60_000

  The `:reap_name_prefix` is a safety switch — the Reaper only terminates
  resources whose `:name` starts with the configured prefix, so it never
  touches pods spawned by other tools on the same RunPod account. Set it to
  `""` to disable the safeguard.

  `:vast` is not in the default `:reap_providers`. A Vast label is free text
  a user types in Vast's console, so the prefix can match an instance ExAtlas
  never rented; opt in once your own instances carry no `atlas-` label.
  `ExAtlas.Orchestrator.spawn/1` warns when a task that can respawn runs on a
  provider outside `:reap_providers`: a node that dies mid-respawn leaves the
  replacement with no record, and only the Reaper deletes it.

  ## "Ours" means the Registry *or* the store

  A tracker in the Registry is the live answer, and it is the only one a node
  has for the first minute after a deploy — which is precisely when a
  multi-hour training run has no tracker and every reason to still be running.
  `:reap_grace_ms` cannot help there: it is keyed off `created_at`, and a pod
  that has been training for three hours is not young by any reading of it.

  So an id recorded in the `ExAtlas.Orchestrator.TrackingStore` is ours too,
  whether or not `ExAtlas.Orchestrator.Adopter` has reached it yet. An id in
  neither is an orphan.

  ## The adoption gate

  Between "the store is loaded" and "the trackers are running", every
  adoptable resource looks exactly like an orphan. So a Reaper that has a
  store configured starts **gated**: it does nothing on a tick until the
  Adopter has signalled `:adoption_complete`.

  If the Adopter signals `:adoption_failed` — the store could not be read —
  reaping stays off for the **entire boot**. A node that cannot account for
  which running compute is its own must never issue a DELETE; a leak is
  bounded by `:max_runtime_ms` and an operator reading the log, while a
  wrongly reaped task is hours of GPU spend that no longer exists.

  The Adopter runs once per boot, so it records its outcome before it sends
  it. A Reaper that crashes and restarts reads that record and keeps the gate
  as it was: open after `:adoption_complete`, shut after `:adoption_failed`.
  The record is keyed by the pid of the supervisor the two share. A new tree
  (the app started again in the same VM, or a restarted supervisor) has a new
  pid, so its Reaper starts gated until that tree's Adopter signals.

  With no store configured (`tracking_store: false`) there is nothing to wait
  for and the Reaper behaves exactly as it did before adoption existed.

  ## More than one node: `:reap_owner`

  Every node lists the whole provider account, and its Registry and store
  know only its own pods. So without more information node B sees node A's
  live pods as orphans. Every deployment with more than one machine on one
  account must give each machine an owner name that stays the same across
  its restarts:

      # config/runtime.exs — on Fly, the machine id
      config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")

  `ExAtlas.Orchestrator.spawn/1` then writes the owner into each pod name
  (`atlas-train-42` becomes `atlas-m1-train-42`), and the Reaper deletes only
  untracked pods named with its own owner. It leaves every other pod alone and
  logs each one once per boot: another node's pods, pods named before the
  owner was set, and pods of a node that is gone. With the Ecto store it
  deletes that last kind once their owner is dead (below); otherwise they are
  the operator's to delete. See `ExAtlas.Orchestrator.Ownership`.

  The Reaper reaps nothing, and logs an error, when:

    * `:reap_owner` is invalid;
    * this node has no `:reap_owner` and is connected to other nodes
      (`Node.list/0` is non-empty; hidden nodes such as a remote console do
      not count);
    * a connected node reports the same `:reap_owner` over `:erpc`.

  A connected node that cannot report its owner (an ex_atlas older than
  v0.8.0, or no answer within 5 s) gets one warning per boot, and reaping
  goes on.

  These checks see connected nodes only. A node with no owner that sees no
  peers reaps every untracked prefixed pod, as v0.7.0 did, including the
  pods of machines that share the account without clustering. An owner set
  on only some machines therefore protects nothing: the machines without one
  still delete the others' pods.

  ## A dead owner's pods

  With `ExAtlas.Orchestrator.TrackingStore.Ecto` and a running
  `ExAtlas.Orchestrator.Lease`, the Reaper also deletes an untracked pod
  whose name carries another owner, once `ExAtlas.Orchestrator.Lease.dead_owners/0`
  reports that owner dead: its lease stayed expired, with the same expiry,
  for `:reap_dead_owner_after_ms` (15 minutes by default) while this node
  renewed its own. The rules above still hold: the pod bills, is in neither
  the Registry nor the store, carries the prefix and is past grace. The
  Reaper keeps the pod when a connected node reports that owner, and when
  any connected node cannot report its owner. Each deletion logs a warning
  with the owner and its lease's expiry.

  A node that is alive but cut off from the database, and connected to no
  other node, reads as dead after the window, and so does a node that once
  renewed and now runs no Lease (its callback secret removed, say). Their
  untracked pods go. Cluster the nodes, or raise `:reap_dead_owner_after_ms`.
  A pod a dead owner's record still names stays, as today.

  ## The grace window

  "Not tracked" and "not tracked *yet*" look identical from here. Both
  `ExAtlas.Orchestrator.spawn/1` and the tracker's respawn path create the
  resource before registering it, and that provider call can take tens of
  seconds once retries are involved — a window in which a healthy, brand-new
  resource is running upstream with nothing in the Registry. Reaping inside it
  destroys the resource its caller is about to be handed, and on the respawn
  path burns one replacement from the budget per tick.

  So a resource younger than `:reap_grace_ms` (default: one reap interval) is
  left alone. A resource that reports no `:created_at` gets no grace: when we
  cannot tell how old something is, reclaiming spend is the safer error.

  The grace window is why the Reaper and the trackers' status polls do not
  fight over the same resource — see the README for how the two directions
  compose.
  """

  use GenServer

  require Logger

  alias ExAtlas.Config
  alias ExAtlas.Orchestrator.{ComputeRegistry, Lease, Ownership, TrackingStore}

  @default_interval_ms 60 * 1_000

  # `:vast` stays out: a Vast label is free text a user types in Vast's
  # console, so the `atlas-` marker can match an instance ExAtlas never rented.
  @default_providers [:runpod]

  # A pod that is still booting bills too. Runpod v1's `desiredStatus=RUNNING`
  # filter included booting pods; v2's `status` splits them out.
  @billing_statuses [:provisioning, :running]

  @peer_owner_timeout_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = config()
    schedule(config.interval)

    {:ok,
     Map.merge(config, %{
       adoption: initial_adoption(),
       announced: nil,
       left_alone: MapSet.new(),
       silent_peers: MapSet.new()
     })}
  end

  # A Reaper restarted after the Adopter's one signal takes the outcome its
  # tree recorded, even when the store was switched off since. A new tree has
  # a new supervisor pid, so an outcome from an earlier start of the app never
  # opens its gate. With no record and no store there is nothing to wait for.
  defp initial_adoption do
    cond do
      recorded = recorded_adoption() -> recorded
      TrackingStore.impl() -> :pending
      true -> :settled
    end
  end

  @adoption_key {__MODULE__, :adoption}

  @doc false
  # The Adopter calls this before it signals: the signal is lost when the
  # Reaper is down at that moment, and the record is not. Keyed by the
  # supervisor the caller runs under, which the Reaper shares. Entries of dead
  # supervisors are dropped on each write, so `:persistent_term` sees one
  # write per boot.
  @spec record_adoption(:settled | :failed) :: :ok
  def record_adoption(outcome) when outcome in [:settled, :failed] do
    case tree() do
      nil ->
        :ok

      sup ->
        live =
          @adoption_key
          |> :persistent_term.get(%{})
          |> Map.filter(fn {pid, _outcome} -> Process.alive?(pid) end)

        :persistent_term.put(@adoption_key, Map.put(live, sup, outcome))
    end
  end

  defp recorded_adoption do
    case tree() do
      nil -> nil
      sup -> Map.get(:persistent_term.get(@adoption_key, %{}), sup)
    end
  end

  # The supervisor this process runs under. A GenServer's `proc_lib` start
  # stores a registered parent by name, a Task stores it by pid. A process no
  # supervisor started, such as a test calling `Adopter.run/1`, has no
  # ancestors and records nothing.
  defp tree do
    case Process.get(:"$ancestors") do
      [pid | _] when is_pid(pid) -> pid
      [name | _] when is_atom(name) -> Process.whereis(name)
      _none -> nil
    end
  end

  @impl true
  def handle_info(:reap, state) do
    schedule(state.interval)
    {result, silent} = gate(state)
    state = warn_silent_once(state, silent)

    case result do
      {:ok, owner, peers} ->
        left_alone =
          Enum.reduce(state.providers, state.left_alone, fn provider, seen ->
            reap_provider(provider, state.prefix, state.grace_ms, {owner, peers}, seen)
          end)

        {:noreply, %{state | left_alone: left_alone, announced: nil}}

      {:closed, reason} ->
        {:noreply, announce(state, reason)}
    end
  end

  def handle_info(:adoption_complete, state),
    do: {:noreply, %{state | adoption: :settled, announced: nil}}

  def handle_info(:adoption_failed, state),
    do: {:noreply, %{state | adoption: :failed, announced: nil}}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Adoption has not run yet, or could not: every adoptable resource looks
  # like an orphan. Then the owner: a node that cannot tell its own pods from
  # another node's must not delete any.
  #
  # Each gate returns its result and the connected nodes that could not report
  # their owner, which are warned about but never stop reaping.
  defp gate(%{adoption: :pending}), do: {{:closed, :adoption_pending}, []}
  defp gate(%{adoption: :failed}), do: {{:closed, :adoption_failed}, []}
  defp gate(_state), do: ownership_gate(Ownership.owner())

  defp ownership_gate({:error, error}), do: {{:closed, {:invalid_owner, error}}, []}

  defp ownership_gate({:ok, nil}) do
    if clustered_without_owner?(nil),
      do: {{:closed, :clustered_without_owner}, []},
      else: {{:ok, nil, :no_owner}, []}
  end

  defp ownership_gate({:ok, owner}) do
    %{same: same, silent: silent, owners: owners, unsure: unsure} = ask_peers(owner)

    case same do
      [] -> {{:ok, owner, {owners, unsure}}, silent}
      nodes -> {{:closed, {:duplicate_owner, owner, nodes}}, silent}
    end
  end

  # A connected node that reports an owner is alive, whatever its lease says.
  # One that reports no owner, an invalid one, or cannot report may be the
  # dead owner itself (slow, misconfigured, on an old release), so with any
  # such peer no owner reads as dead this tick.
  defp dead_owners(peers) do
    if reap_dead_owners?(), do: live_dead_owners(peers), else: %{}
  end

  defp live_dead_owners(:no_owner), do: %{}
  defp live_dead_owners({_peer_owners, [_unsure | _]}), do: %{}
  defp live_dead_owners({peer_owners, []}), do: Map.drop(Lease.dead_owners(), peer_owners)

  # On unless set to something other than `true`: a mistyped value leaves
  # pods alone rather than deleting them.
  defp reap_dead_owners? do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:reap_dead_owners, true)
    |> Kernel.==(true)
  end

  # Two nodes with one owner each read the other's pods as their own. Only a
  # reported match stops reaping. A peer that cannot answer (an ex_atlas older
  # than v0.8.0, a timeout) is `:silent`: it cannot be checked, and a v0.7.0
  # node is exactly the one that deletes this node's pods.
  defp ask_peers(owner) do
    peers = Enum.sort(Node.list())

    peers
    |> :erpc.multicall(Ownership, :owner, [], @peer_owner_timeout_ms)
    |> Enum.zip(peers)
    |> Enum.reduce(%{same: [], silent: [], owners: [], unsure: []}, fn
      {{:ok, {:ok, ^owner}}, node}, acc ->
        %{acc | same: acc.same ++ [node]}

      {{:ok, {:ok, other}}, _node}, acc when is_binary(other) ->
        %{acc | owners: [other | acc.owners]}

      {{:error, _reason}, node}, acc ->
        %{acc | silent: acc.silent ++ [node], unsure: [node | acc.unsure]}

      {_no_or_invalid_owner, node}, acc ->
        %{acc | unsure: [node | acc.unsure]}
    end)
  end

  defp warn_silent_once(state, silent) do
    new = Enum.reject(silent, &MapSet.member?(state.silent_peers, &1))
    Enum.each(new, &warn_silent/1)
    %{state | silent_peers: MapSet.union(state.silent_peers, MapSet.new(new))}
  end

  defp warn_silent(node) do
    Logger.warning(
      "[ExAtlas.Orchestrator.Reaper] connected node #{node} cannot report its :reap_owner " <>
        "(an ex_atlas older than v0.8.0, or no answer within #{@peer_owner_timeout_ms} ms), " <>
        "so it cannot be checked for a duplicate owner. A v0.7.0 node deletes this node's " <>
        "pods: finish the two-deploy upgrade in the CHANGELOG."
    )
  end

  # Once per state change, not once per tick: an operator needs to know the
  # Reaper is off, and needs it to still be readable an hour later.
  defp announce(%{announced: reason} = state, reason), do: state

  defp announce(state, reason) do
    log_closed(reason)
    %{state | announced: reason}
  end

  defp log_closed(:adoption_failed) do
    Logger.error(
      "[ExAtlas.Orchestrator.Reaper] reaping is DISABLED for this boot: the tracking store " <>
        "could not be read, so this node cannot tell which running compute is its own. " <>
        "Untracked compute will keep billing until you reclaim it by hand."
    )
  end

  defp log_closed(:adoption_pending) do
    Logger.info(
      "[ExAtlas.Orchestrator.Reaper] skipping this cycle until boot-time adoption settles"
    )
  end

  defp log_closed({:invalid_owner, error}) do
    Logger.error(
      "[ExAtlas.Orchestrator.Reaper] reaping is DISABLED: #{Exception.message(error)}. " <>
        "Untracked compute will keep billing until you fix :reap_owner."
    )
  end

  defp log_closed({:duplicate_owner, owner, nodes}) do
    Logger.error(
      "[ExAtlas.Orchestrator.Reaper] reaping is DISABLED: :reap_owner #{inspect(owner)} is also " <>
        "set on #{Enum.map_join(nodes, ", ", &Atom.to_string/1)}. Nodes that share an owner " <>
        "delete each other's pods. Give each node its own owner, for example " <>
        ~s|System.get_env("FLY_MACHINE_ID").|
    )
  end

  defp log_closed(:clustered_without_owner) do
    Logger.error(
      "[ExAtlas.Orchestrator.Reaper] reaping is DISABLED: this node is connected to " <>
        "#{length(Node.list())} other node(s) and has no :reap_owner, so it cannot tell its " <>
        "own untracked compute from another node's. Set a name that stays the same across " <>
        "restarts, for example in config/runtime.exs: " <>
        ~s|config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")|
    )
  end

  @doc """
  Run a single reap cycle. Useful in tests.

  It applies the owner rules of a periodic tick, but not the adoption gate, and
  it logs every pod it leaves alone.
  """
  def reap_now(prefix \\ "atlas-", providers \\ @default_providers) do
    grace_ms = config().grace_ms

    {result, silent} = ownership_gate(Ownership.owner())
    Enum.each(silent, &warn_silent/1)

    case result do
      {:ok, owner, peers} ->
        Enum.each(providers, &reap_provider(&1, prefix, grace_ms, {owner, peers}, MapSet.new()))

      {:closed, reason} ->
        log_closed(reason)
    end

    :ok
  end

  defp config do
    cfg = Application.get_env(:ex_atlas, :orchestrator, [])
    interval = Keyword.get(cfg, :reap_interval_ms, @default_interval_ms)

    %{
      interval: interval,
      providers: providers(),
      prefix: Ownership.prefix(),
      grace_ms: Keyword.get(cfg, :reap_grace_ms, interval)
    }
  end

  @doc false
  # Why this node's Reaper would never delete `compute` of `provider` once
  # nothing tracks it, or nil: the provider, the status, the cluster and the
  # name, as a tick decides them. The Adopter adopts a record this node did not
  # sign only when this is nil (issue 138), since an adopted task deletes its
  # pod. A connected peer that shares `owner` is not checked here.
  @spec refusal(atom() | module(), ExAtlas.Spec.Compute.t(), String.t() | nil) ::
          String.t() | nil
  def refusal(provider, compute, owner) do
    prefix = Ownership.prefix()

    cond do
      not covers?(provider) ->
        "#{inspect(provider)} is not in :reap_providers"

      compute.status not in @billing_statuses ->
        "the provider reports it #{inspect(compute.status)}, and the Reaper deletes only " <>
          "a pod that bills (#{Enum.map_join(@billing_statuses, ", ", &inspect/1)})"

      clustered_without_owner?(owner) ->
        "this node has no :reap_owner and is connected to other nodes"

      not Ownership.ours?(compute.name, prefix, owner) ->
        "the provider names the pod #{inspect(compute.name)}, which the Reaper does not " <>
          "delete (:reap_name_prefix #{inspect(prefix)}, :reap_owner #{inspect(owner)})"

      true ->
        nil
    end
  end

  defp clustered_without_owner?(owner), do: owner == nil and Node.list() != []

  @doc """
  Whether a periodic Reaper reclaims `provider`'s orphans: whether it is in
  `:reap_providers`, by atom or by module.
  """
  @spec covers?(atom() | module()) :: boolean()
  def covers?(provider) do
    module = provider_module(provider)
    Enum.any?(providers(), &(provider_module(&1) == module))
  end

  defp providers do
    :ex_atlas
    |> Application.get_env(:orchestrator, [])
    |> Keyword.get(:reap_providers, @default_providers)
  end

  # No raise: an unknown name in `:reap_providers` is the Reaper's to report
  # on its tick, not a spawn's.
  defp provider_module(provider), do: Map.get(Config.builtin_providers(), provider, provider)

  # Returns the ids left alone so far, so a periodic Reaper logs each one once
  # per boot rather than once per tick.
  defp reap_provider(provider, prefix, grace_ms, {owner, peers}, left_alone) do
    case list_compute(provider) do
      {:ok, computes} ->
        tracked = registered_ids()
        store = TrackingStore.impl()
        now = DateTime.utc_now()

        {ours, others} =
          computes
          |> Enum.filter(&orphan?(&1, tracked, store, prefix, now, grace_ms))
          |> Enum.split_with(&Ownership.ours?(&1.name, prefix, owner))

        # Read after the list, which can take tens of seconds: an owner that
        # renewed meanwhile is no longer dead.
        dead = if others == [], do: %{}, else: dead_owners(peers)
        {dead_owners, others} = Enum.split_with(others, &dead_owner(&1, prefix, owner, dead))

        Enum.each(ours, &delete_ours(&1, provider))

        Enum.each(
          dead_owners,
          &delete_dead_owners(&1, provider, dead_owner(&1, prefix, owner, dead))
        )

        Enum.reduce(others, left_alone, &leave_alone(&1, prefix, owner, &2))

      _ ->
        left_alone
    end
  end

  # The dead owner `compute`'s name carries, or nil.
  defp dead_owner(compute, prefix, owner, dead) do
    case Ownership.classify(compute.name, prefix, owner) do
      {:other, other} when is_map_key(dead, other) -> {other, Map.fetch!(dead, other)}
      _ours_live_or_unowned -> nil
    end
  end

  defp delete_ours(compute, provider) do
    case delete_compute(compute, provider) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Reaper] could not delete #{compute.id} (#{compute.name})" <>
            "#{failure_kind(error)}; the next tick tries again"
        )
    end
  end

  defp delete_dead_owners(compute, provider, {other, expired_at}) do
    case delete_compute(compute, provider) do
      :ok ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Reaper] deleted #{compute.id} (#{compute.name}): owner " <>
            "#{inspect(other)} has not renewed its lease since #{since(expired_at)}, and no " <>
            "connected node reports it"
        )

      {:error, error} ->
        Logger.warning(
          "[ExAtlas.Orchestrator.Reaper] could not delete #{compute.id} (#{compute.name}) of " <>
            "dead owner #{inspect(other)}#{failure_kind(error)}; the next tick tries again"
        )
    end
  end

  # A delete that raises or exits skips that pod, not the tick: the rest of
  # this provider's orphans, and every later provider's, still go. Only the
  # error's kind is logged, never its message, which can carry a provider's
  # response.
  defp delete_compute(compute, provider) do
    ExAtlas.terminate(compute.id, provider: provider)
  rescue
    error -> {:error, error}
  catch
    :exit, _reason -> {:error, :exit}
  end

  defp failure_kind(%ExAtlas.Error{kind: kind}), do: " (#{inspect(kind)})"
  defp failure_kind(%{__exception__: true} = error), do: " (#{inspect(error.__struct__)})"
  defp failure_kind(:exit), do: " (exited)"
  defp failure_kind(_other), do: ""

  defp since(ms) do
    case DateTime.from_unix(ms, :millisecond) do
      {:ok, at} -> DateTime.to_iso8601(at)
      {:error, _out_of_range} -> "#{ms} ms after the epoch"
    end
  end

  # A list that raises (RunPod with no API key, which the default
  # `reap_providers` lists on a Vast-only host) or exits (an HTTP pool
  # checkout that times out) skips that provider, not the tick: a crash would
  # restart the Reaper gated, and no Adopter signals again. The log keeps the
  # error's kind, never its message or exit reason, which can carry a
  # provider's response.
  defp list_compute(provider) do
    ExAtlas.list_compute(provider: provider)
  rescue
    error ->
      Logger.warning(
        "[ExAtlas.Orchestrator.Reaper] listing #{inspect(provider)} raised " <>
          "#{inspect(error.__struct__)}#{error_kind(error)}; its orphans are not reaped this " <>
          "tick. Configure its API key, or remove it from :reap_providers."
      )

      :error
  catch
    :exit, _reason ->
      Logger.warning(
        "[ExAtlas.Orchestrator.Reaper] listing #{inspect(provider)} exited; its orphans are " <>
          "not reaped this tick."
      )

      :error
  end

  defp error_kind(%ExAtlas.Error{kind: kind}), do: " (#{inspect(kind)})"
  defp error_kind(_error), do: ""

  defp leave_alone(compute, prefix, owner, seen) do
    if MapSet.member?(seen, compute.id) do
      seen
    else
      Logger.warning(
        "[ExAtlas.Orchestrator.Reaper] leaving #{compute.id} (#{compute.name}) alone: " <>
          "#{describe_owner(Ownership.classify(compute.name, prefix, owner))}, " <>
          "and this node's :reap_owner is #{inspect(owner)}. If no node owns it any more, " <>
          "delete it by hand."
      )

      MapSet.put(seen, compute.id)
    end
  end

  defp describe_owner({:other, other}),
    do:
      "its name carries owner #{inspect(other)} (another node's, or a name from before " <>
        "owners existed)"

  defp describe_owner(:unowned), do: "its name carries no owner"

  defp orphan?(compute, tracked, store, prefix, now, grace_ms) do
    compute.status in @billing_statuses and
      not MapSet.member?(tracked, compute.id) and
      not ours?(store, compute.id) and
      is_binary(compute.name) and
      String.starts_with?(compute.name, prefix) and
      not young?(compute, now, grace_ms)
  end

  # The second half of the "is this ours?" question, and the reason a deploy no
  # longer destroys a running task: in the Registry means a tracker has it, in
  # the store means we spawned it and adoption either has it or decided it was
  # gone. Only an id in neither is an orphan.
  defp ours?(nil, _id), do: false

  defp ours?(store, id) do
    match?({:ok, _record}, store.get(id))
  rescue
    # A store implementation that raises is not evidence that a live resource
    # belongs to somebody else. Uncertainty always resolves towards leaving it
    # alone — and a raise here must not crash-loop the Reaper either.
    error ->
      Logger.error(
        "[ExAtlas.Orchestrator.Reaper] tracking store raised for #{id} " <>
          "(#{inspect(error)}); treating it as ours and terminating nothing"
      )

      true
  end

  # `created_at` is the provider's clock, so a skewed one shifts the window:
  # skewed forward the resource looks younger and is spared, skewed back it
  # looks older and is reaped as before. Neither is worse than reaping
  # everything the instant it appears.
  defp young?(%{created_at: %DateTime{} = created_at}, now, grace_ms),
    do: DateTime.diff(now, created_at, :millisecond) < grace_ms

  defp young?(_compute, _now, _grace_ms), do: false

  defp registered_ids do
    ComputeRegistry
    |> Registry.select([{{{:compute, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  defp schedule(interval) do
    Process.send_after(self(), :reap, interval)
  end
end
