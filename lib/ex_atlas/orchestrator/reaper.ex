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
        reap_name_prefix: "atlas-"

  The `:reap_name_prefix` is a safety switch — the Reaper only terminates
  resources whose `:name` starts with the configured prefix, so it never
  touches pods spawned by other tools on the same RunPod account. Set it to
  `""` to disable the safeguard.
  """

  use GenServer

  alias ExAtlas.Orchestrator.ComputeRegistry

  @default_interval_ms 60 * 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    cfg = Application.get_env(:ex_atlas, :orchestrator, [])
    interval = Keyword.get(cfg, :reap_interval_ms, @default_interval_ms)
    providers = Keyword.get(cfg, :reap_providers, [:runpod])
    prefix = Keyword.get(cfg, :reap_name_prefix, "atlas-")

    schedule(interval)
    {:ok, %{interval: interval, providers: providers, prefix: prefix}}
  end

  @impl true
  def handle_info(:reap, state) do
    Enum.each(state.providers, &reap_provider(&1, state.prefix))
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Run a single reap cycle. Useful in tests."
  def reap_now(prefix \\ "atlas-", providers \\ [:runpod]) do
    Enum.each(providers, &reap_provider(&1, prefix))
    :ok
  end

  defp reap_provider(provider, prefix) do
    case ExAtlas.list_compute(provider: provider, status: :running) do
      {:ok, computes} ->
        tracked = registered_ids()

        computes
        |> Enum.filter(&orphan?(&1, tracked, prefix))
        |> Enum.each(fn compute ->
          _ = ExAtlas.terminate(compute.id, provider: provider)
        end)

      _ ->
        :ok
    end
  end

  defp orphan?(%{id: id, name: name}, tracked, prefix) do
    not MapSet.member?(tracked, id) and is_binary(name) and String.starts_with?(name, prefix)
  end

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
