defmodule ExAtlas.Fly.Logs.Streamer do
  @moduledoc """
  Per-app GenServer that polls the Fly log API and dispatches new entries.

  Each Streamer:

    * owns a single app's log cursor,
    * polls every `:poll_interval` ms,
    * dispatches `{:ex_atlas_fly_logs, app_name, entries}` on topic
      `"ex_atlas_fly_logs:\#{app_name}"` via `ExAtlas.Fly.Dispatcher`,
    * monitors its subscribers and stops once all have disconnected.

  Uses `ExAtlas.Fly.Logs.Client.fetch_logs_with_retry/2` for automatic 401 retry.

  ## Options

    * `:app_name` (required)
    * `:project_dir` (required) — currently unused by the log path, retained
      for future use and to mirror the udin_code API surface.
    * `:poll_interval` — ms between polls, default 2000.
    * `:retry_fetch_fn` — injection point for tests.
    * `:registry` / `:dynamic_sup` — set by `StreamerSupervisor`.
  """

  use GenServer

  require Logger

  alias ExAtlas.Fly.Dispatcher
  alias ExAtlas.Fly.Logs.Client

  @default_poll_interval 2_000

  def start_link(opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    registry = Keyword.get(opts, :registry)

    name =
      if registry do
        {:via, Registry, {registry, app_name}}
      else
        nil
      end

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Subscribes the calling pid to log events for `app_name`, starting a Streamer
  if one isn't already running.

  Returns `{:error, :no_streamer}` when neither a running Streamer nor the
  means to start one (registry + dynamic_sup) is available — this was
  previously a silent `:ok` that delivered no messages. `ExAtlas.Fly.subscribe_logs/3`
  always plumbs both, so the error branch is primarily a programmer-error
  guard for direct callers / test utilities.
  """
  @spec subscribe(String.t(), String.t(), keyword()) :: :ok | {:error, :no_streamer}
  def subscribe(app_name, project_dir, opts \\ []) do
    Dispatcher.subscribe("ex_atlas_fly_logs:#{app_name}")

    registry = Keyword.get(opts, :registry)
    dynamic_sup = Keyword.get(opts, :dynamic_sup)

    case resolve_streamer_pid(app_name, project_dir, registry, dynamic_sup) do
      {:ok, pid} ->
        subscribe_pid(pid, self())
        :ok

      :none ->
        {:error, :no_streamer}
    end
  end

  defp resolve_streamer_pid(_app_name, _project_dir, nil, _dynamic_sup), do: :none

  defp resolve_streamer_pid(app_name, project_dir, registry, dynamic_sup) do
    case Registry.lookup(registry, app_name) do
      [{pid, _}] ->
        {:ok, pid}

      [] when not is_nil(dynamic_sup) ->
        {:ok, pid} =
          DynamicSupervisor.start_child(
            dynamic_sup,
            {__MODULE__,
             [
               app_name: app_name,
               project_dir: project_dir,
               registry: registry,
               dynamic_sup: dynamic_sup
             ]}
          )

        {:ok, pid}

      _ ->
        :none
    end
  end

  @doc "Register `subscriber_pid` as a subscriber of `streamer_pid`."
  def subscribe_pid(streamer_pid, subscriber_pid) do
    GenServer.call(streamer_pid, {:subscribe, subscriber_pid})
  end

  # ── Server callbacks ──

  @impl GenServer
  def init(opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    project_dir = Keyword.fetch!(opts, :project_dir)

    state = %{
      app_name: app_name,
      project_dir: project_dir,
      start_time: nil,
      subscribers: %{},
      retry_fetch_fn: Keyword.get(opts, :retry_fetch_fn, &Client.fetch_logs_with_retry/2),
      poll_interval: Keyword.get(opts, :poll_interval, poll_interval())
    }

    {:ok, state, {:continue, :initial_fetch}}
  end

  @impl GenServer
  def handle_continue(:initial_fetch, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = do_poll(state)
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    subscribers = Map.delete(state.subscribers, ref)

    if map_size(subscribers) == 0 do
      {:stop, :normal, %{state | subscribers: subscribers}}
    else
      {:noreply, %{state | subscribers: subscribers}}
    end
  end

  # ── Private ──

  defp do_poll(state) do
    opts = if state.start_time, do: [start_time: state.start_time], else: []

    case state.retry_fetch_fn.(state.app_name, opts) do
      {:ok, []} ->
        state

      {:ok, entries} ->
        Dispatcher.dispatch(
          "ex_atlas_fly_logs:#{state.app_name}",
          {:ex_atlas_fly_logs, state.app_name, entries}
        )

        next_time = Client.next_start_time(entries)
        %{state | start_time: next_time}

      {:error, reason} ->
        Logger.warning(
          "[ExAtlas.Fly.Logs.Streamer] Fetch failed for #{state.app_name}: #{inspect(reason)}"
        )

        state
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_interval do
    Application.get_env(:ex_atlas, :fly, [])[:poll_interval_ms] || @default_poll_interval
  end
end
