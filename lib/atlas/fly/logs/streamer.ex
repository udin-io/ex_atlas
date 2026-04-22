defmodule Atlas.Fly.Logs.Streamer do
  @moduledoc """
  Per-app GenServer that polls the Fly log API and dispatches new entries.

  Each Streamer:

    * owns a single app's log cursor,
    * polls every `:poll_interval` ms,
    * dispatches `{:atlas_fly_logs, app_name, entries}` on topic
      `"atlas_fly_logs:\#{app_name}"` via `Atlas.Fly.Dispatcher`,
    * monitors its subscribers and stops once all have disconnected.

  Uses `Atlas.Fly.Logs.Client.fetch_logs_with_retry/2` for automatic 401 retry.

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

  alias Atlas.Fly.Dispatcher
  alias Atlas.Fly.Logs.Client

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
  """
  @spec subscribe(String.t(), String.t(), keyword()) :: :ok
  def subscribe(app_name, project_dir, opts \\ []) do
    Dispatcher.subscribe("atlas_fly_logs:#{app_name}")

    registry = Keyword.get(opts, :registry)
    dynamic_sup = Keyword.get(opts, :dynamic_sup)

    streamer_pid =
      cond do
        is_nil(registry) ->
          nil

        true ->
          case Registry.lookup(registry, app_name) do
            [{pid, _}] ->
              pid

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

              pid

            _ ->
              nil
          end
      end

    if streamer_pid, do: subscribe_pid(streamer_pid, self())

    :ok
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
          "atlas_fly_logs:#{state.app_name}",
          {:atlas_fly_logs, state.app_name, entries}
        )

        next_time = Client.next_start_time(entries)
        %{state | start_time: next_time}

      {:error, reason} ->
        Logger.warning(
          "[Atlas.Fly.Logs.Streamer] Fetch failed for #{state.app_name}: #{inspect(reason)}"
        )

        state
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp poll_interval do
    Application.get_env(:atlas, :fly, [])[:poll_interval_ms] || @default_poll_interval
  end
end
