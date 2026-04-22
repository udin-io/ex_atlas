defmodule ExAtlas.Orchestrator.ComputeServer do
  @moduledoc """
  One `GenServer` per tracked compute resource.

  Responsibilities:

    * Hold the resource's normalized `ExAtlas.Spec.Compute`, its `:user_id`,
      `:idle_ttl_ms`, last-activity timestamp, and spawn opts.
    * Trap exits so `terminate/2` always calls `ExAtlas.terminate/2` on the
      upstream provider — even on supervisor shutdown or crash.
    * Drive its own idle reaper via the GenServer `timeout:` reply element:
      every message resets the timeout; hitting it stops the server normally
      and terminates the upstream resource.
    * Broadcast state changes over `Phoenix.PubSub` via
      `ExAtlas.Orchestrator.Events`.

  Per project conventions, callback bodies never wrap logic in `try/rescue` —
  if a provider API raises, we let the server crash and the supervisor
  handles restart policy. The `terminate/2` callback handles upstream teardown.
  """

  use GenServer

  alias ExAtlas.Orchestrator.{ComputeRegistry, Events}

  @default_idle_ttl_ms 30 * 60 * 1_000
  @default_heartbeat_interval_ms 60 * 1_000

  @type state :: %{
          compute: ExAtlas.Spec.Compute.t(),
          opts: keyword(),
          idle_ttl_ms: pos_integer(),
          heartbeat_ms: pos_integer(),
          last_activity_ms: integer(),
          user_id: term() | nil
        }

  @doc false
  def start_link({compute, opts}) do
    name = {:via, Registry, {ComputeRegistry, {:compute, compute.id}}}
    GenServer.start_link(__MODULE__, {compute, opts}, name: name)
  end

  def child_spec({compute, opts}) do
    %{
      id: {:compute_server, compute.id},
      start: {__MODULE__, :start_link, [{compute, opts}]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Bump last-activity so the idle reaper waits another `idle_ttl_ms`."
  def touch(pid), do: GenServer.cast(pid, :touch)

  @doc "Return the current tracked state."
  def info(pid), do: GenServer.call(pid, :info)

  # --- callbacks ---

  @impl true
  def init({compute, opts}) do
    Process.flag(:trap_exit, true)

    idle_ttl = Keyword.get(opts, :idle_ttl_ms, @default_idle_ttl_ms)
    heartbeat = Keyword.get(opts, :heartbeat_ms, @default_heartbeat_interval_ms)

    state = %{
      compute: compute,
      opts: opts,
      idle_ttl_ms: idle_ttl,
      heartbeat_ms: heartbeat,
      last_activity_ms: now_ms(),
      user_id: Keyword.get(opts, :user_id)
    }

    Events.broadcast(compute.id, {:status, compute.status})
    schedule_heartbeat(heartbeat)
    {:ok, state}
  end

  @impl true
  def handle_cast(:touch, state) do
    {:noreply, %{state | last_activity_ms: now_ms()}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:compute, :last_activity_ms, :user_id, :idle_ttl_ms]), state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    idle_for = now_ms() - state.last_activity_ms

    if idle_for >= state.idle_ttl_ms do
      Events.broadcast(state.compute.id, {:terminating, :idle_timeout})
      {:stop, :normal, state}
    else
      Events.broadcast(state.compute.id, {:heartbeat, now_ms()})
      schedule_heartbeat(state.heartbeat_ms)
      {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Events.broadcast(state.compute.id, {:terminating, reason})

    case ExAtlas.terminate(state.compute.id, state.opts) do
      :ok ->
        Events.broadcast(state.compute.id, {:status, :terminated})
        :ok

      {:error, err} ->
        Events.broadcast(state.compute.id, {:terminate_failed, err})
        :ok
    end
  end

  defp schedule_heartbeat(ms), do: Process.send_after(self(), :heartbeat, ms)
  defp now_ms, do: System.monotonic_time(:millisecond)
end
