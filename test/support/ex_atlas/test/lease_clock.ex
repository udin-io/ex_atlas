defmodule ExAtlas.Test.LeaseClock do
  @moduledoc """
  An `ExAtlas.Orchestrator.Lease` on two clocks a test steps: the wall clock
  it renews and reads expiries with, and the monotonic clock it times
  `:reap_dead_owner_after_ms` on. Start it with a `:ttl_ms` long enough that
  no tick fires on its own; it renews when the test steps it.
  """

  import ExUnit.Callbacks

  alias ExAtlas.Orchestrator.Lease

  defstruct [:pid, :wall, :mono, :step, :opts]

  @doc """
  Start a Lease under the test supervisor with `opts` (`:store`, `:owner`,
  `:ttl_ms`), its wall clock at now and its monotonic clock at 0.
  """
  def start!(opts) do
    {:ok, wall} = Agent.start_link(fn -> System.system_time(:millisecond) end)
    {:ok, mono} = Agent.start_link(fn -> 0 end)
    restart!(%__MODULE__{wall: wall, mono: mono, step: div(opts[:ttl_ms], 3), opts: opts})
  end

  @doc "Stop the Lease and start a new one on the same clocks, as a crash would."
  def restart!(lease) do
    if Process.whereis(Lease), do: stop_supervised!(Lease)

    clocks = [
      clock: fn -> Agent.get(lease.wall, & &1) end,
      monotonic: fn -> Agent.get(lease.mono, & &1) end
    ]

    pid = start_supervised!({Lease, Keyword.merge(lease.opts, clocks)})
    # `init/1` queues the first tick before any call, so this returns after it.
    :sys.get_state(pid)
    %{lease | pid: pid}
  end

  @doc "Move the wall clock by `wall_ms` and the monotonic clock by `mono_ms`, then tick."
  def step!(lease, wall_ms, mono_ms) do
    Agent.update(lease.wall, &(&1 + wall_ms))
    Agent.update(lease.mono, &(&1 + mono_ms))
    tick!(lease)
  end

  @doc "Move the monotonic clock alone, with no tick: a renewal that never came."
  def stall!(lease, mono_ms), do: Agent.update(lease.mono, &(&1 + mono_ms))

  @doc """
  Run both clocks on together for `ms`, with a renewal every third of a ttl,
  as a live node renews.
  """
  def run_for!(%{step: step} = lease, ms) when ms <= step, do: step!(lease, ms, ms)

  def run_for!(lease, ms) do
    step!(lease, lease.step, lease.step)
    run_for!(lease, ms - lease.step)
  end

  defp tick!(lease) do
    send(lease.pid, :tick)
    :sys.get_state(lease.pid)
    :ok
  end
end
