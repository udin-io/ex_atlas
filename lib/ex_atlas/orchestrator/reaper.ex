defmodule ExAtlas.Orchestrator.Reaper do
  @moduledoc """
  Periodic reconciliation GenServer.

  On each tick, the Reaper:

    1. Asks each tracked provider for its list of live resources.
    2. Compares against the `ComputeServer` processes in the Registry **and**
       the `ExAtlas.Orchestrator.TrackingStore`.
    3. Flags any resource that exists at the provider but appears in neither
       (symptom of a node restart after a crash) and calls
       `ExAtlas.terminate/2` to reclaim the runaway spend.

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

  With no store configured (`tracking_store: false`) there is nothing to wait
  for and the Reaper behaves exactly as it did before adoption existed.

  ## One orchestrating node

  The Reaper is unsafe on two or more nodes sharing a provider account *and* a
  `:reap_name_prefix`, and always has been: node B lists the account, sees node
  A's pods as untracked, and terminates them once the grace window passes.
  Per-node tracking stores do not fix that — node B's store simply has no
  record of node A's pods either. See issue #38. Run one orchestrating node, or
  give each node its own `:reap_name_prefix`.

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

  alias ExAtlas.Orchestrator.{ComputeRegistry, TrackingStore}

  @default_interval_ms 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = config()
    schedule(config.interval)
    {:ok, Map.merge(config, %{adoption: initial_adoption(), announced?: false})}
  end

  # With no tracking store there is nothing to adopt and nothing to wait for,
  # so the Reaper behaves exactly as it did before adoption existed.
  defp initial_adoption do
    if TrackingStore.impl(), do: :pending, else: :settled
  end

  @impl true
  def handle_info(:reap, %{adoption: :settled} = state) do
    Enum.each(state.providers, &reap_provider(&1, state.prefix, state.grace_ms))
    schedule(state.interval)
    {:noreply, state}
  end

  # Adoption has not run yet, or could not. Either way every adoptable resource
  # currently looks exactly like an orphan, so this tick does nothing at all.
  def handle_info(:reap, state) do
    schedule(state.interval)
    {:noreply, announce(state)}
  end

  def handle_info(:adoption_complete, state),
    do: {:noreply, %{state | adoption: :settled, announced?: false}}

  def handle_info(:adoption_failed, state),
    do: {:noreply, %{state | adoption: :failed, announced?: false}}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Once per state change, not once per tick: an operator needs to know the
  # Reaper is off, and needs it to still be readable an hour later.
  defp announce(%{announced?: true} = state), do: state

  defp announce(%{adoption: :failed} = state) do
    Logger.error(
      "[ExAtlas.Orchestrator.Reaper] reaping is DISABLED for this boot: the tracking store " <>
        "could not be read, so this node cannot tell which running compute is its own. " <>
        "Untracked compute will keep billing until you reclaim it by hand."
    )

    %{state | announced?: true}
  end

  defp announce(state) do
    Logger.info(
      "[ExAtlas.Orchestrator.Reaper] skipping this cycle until boot-time adoption settles"
    )

    %{state | announced?: true}
  end

  @doc "Run a single reap cycle. Useful in tests."
  def reap_now(prefix \\ "atlas-", providers \\ [:runpod]) do
    grace_ms = config().grace_ms
    Enum.each(providers, &reap_provider(&1, prefix, grace_ms))
    :ok
  end

  defp config do
    cfg = Application.get_env(:ex_atlas, :orchestrator, [])
    interval = Keyword.get(cfg, :reap_interval_ms, @default_interval_ms)

    %{
      interval: interval,
      providers: Keyword.get(cfg, :reap_providers, [:runpod]),
      prefix: Keyword.get(cfg, :reap_name_prefix, "atlas-"),
      grace_ms: Keyword.get(cfg, :reap_grace_ms, interval)
    }
  end

  defp reap_provider(provider, prefix, grace_ms) do
    case ExAtlas.list_compute(provider: provider, status: :running) do
      {:ok, computes} ->
        tracked = registered_ids()
        store = TrackingStore.impl()
        now = DateTime.utc_now()

        computes
        |> Enum.filter(&orphan?(&1, tracked, store, prefix, now, grace_ms))
        |> Enum.each(fn compute ->
          _ = ExAtlas.terminate(compute.id, provider: provider)
        end)

      _ ->
        :ok
    end
  end

  defp orphan?(compute, tracked, store, prefix, now, grace_ms) do
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
