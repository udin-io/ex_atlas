defmodule ExAtlas.Orchestrator.Reaper do
  @moduledoc """
  Periodic reconciliation GenServer.

  On each tick, the Reaper:

    1. Asks each tracked provider for its list of live resources.
    2. Compares against the `ComputeServer` processes in the Registry.
    3. Flags any resource that exists at the provider but has no local tracker
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

  alias ExAtlas.Orchestrator.ComputeRegistry

  @default_interval_ms 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = config()
    schedule(config.interval)
    {:ok, config}
  end

  @impl true
  def handle_info(:reap, state) do
    Enum.each(state.providers, &reap_provider(&1, state.prefix, state.grace_ms))
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

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
        now = DateTime.utc_now()

        computes
        |> Enum.filter(&orphan?(&1, tracked, prefix, now, grace_ms))
        |> Enum.each(fn compute ->
          _ = ExAtlas.terminate(compute.id, provider: provider)
        end)

      _ ->
        :ok
    end
  end

  defp orphan?(compute, tracked, prefix, now, grace_ms) do
    not MapSet.member?(tracked, compute.id) and
      is_binary(compute.name) and
      String.starts_with?(compute.name, prefix) and
      not young?(compute, now, grace_ms)
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
