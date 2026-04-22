defmodule ExAtlas.Fly.Logs.StreamerTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Fly.Dispatcher
  alias ExAtlas.Fly.Logs.{LogEntry, Streamer, StreamerSupervisor}

  @moduletag :fly_logs

  defp make_entries(count, app_name \\ "test-app") do
    for i <- 1..count do
      %LogEntry{
        timestamp: "2024-01-01T00:00:0#{i}Z",
        message: "Log line #{i}",
        level: "info",
        region: "cdg",
        instance: "abc123",
        app_name: app_name
      }
    end
  end

  defp start_streamer(opts) do
    app_name = Keyword.get(opts, :app_name, "test-app-#{System.unique_integer([:positive])}")
    project_dir = Keyword.get(opts, :project_dir, "/tmp/test")
    poll_interval = Keyword.get(opts, :poll_interval, 50)
    retry_fetch_fn = Keyword.fetch!(opts, :retry_fetch_fn)

    streamer_opts = [
      app_name: app_name,
      project_dir: project_dir,
      poll_interval: poll_interval,
      retry_fetch_fn: retry_fetch_fn
    ]

    pid = start_supervised!({Streamer, streamer_opts})
    %{pid: pid, app_name: app_name}
  end

  describe "initial fetch and broadcasting" do
    test "fetches initial logs on start and dispatches via the registry" do
      test_pid = self()
      entries = make_entries(3)

      retry_fetch_fn = fn _app, _opts ->
        send(test_pid, :fetch_called)
        {:ok, entries}
      end

      app_name = "initial-fetch-#{System.unique_integer([:positive])}"

      # Subscribe BEFORE starting streamer, since initial fetch fires immediately.
      Dispatcher.subscribe("ex_atlas_fly_logs:#{app_name}")

      start_supervised!(
        {Streamer,
         [
           app_name: app_name,
           project_dir: "/tmp/test",
           poll_interval: 60_000,
           retry_fetch_fn: retry_fetch_fn
         ]}
      )

      assert_receive :fetch_called, 1_000
      assert_receive {:ex_atlas_fly_logs, ^app_name, received}, 1_000
      assert length(received) == 3
    end

    test "does not broadcast when no entries returned" do
      test_pid = self()

      retry_fetch_fn = fn _app, _opts ->
        send(test_pid, :fetch_called)
        {:ok, []}
      end

      %{app_name: app_name} =
        start_streamer(retry_fetch_fn: retry_fetch_fn, poll_interval: 60_000)

      Dispatcher.subscribe("ex_atlas_fly_logs:#{app_name}")

      assert_receive :fetch_called, 1_000
      refute_receive {:ex_atlas_fly_logs, _, _}, 200
    end
  end

  describe "polling and start_time advancement" do
    test "advances start_time on subsequent polls" do
      test_pid = self()
      entries = make_entries(3)
      call_count = :counters.new(1, [:atomics])

      retry_fetch_fn = fn _app, opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)
        send(test_pid, {:fetch_called, count, opts})

        if count == 1, do: {:ok, entries}, else: {:ok, []}
      end

      start_streamer(retry_fetch_fn: retry_fetch_fn, poll_interval: 50)

      assert_receive {:fetch_called, 1, opts1}, 1_000
      refute Keyword.has_key?(opts1, :start_time)

      assert_receive {:fetch_called, 2, opts2}, 1_000
      assert is_integer(Keyword.get(opts2, :start_time))
    end
  end

  describe "subscriber management" do
    test "stops when no subscribers remain" do
      test_pid = self()

      retry_fetch_fn = fn _app, _opts ->
        send(test_pid, :fetch_called)
        {:ok, []}
      end

      %{pid: streamer_pid} =
        start_streamer(retry_fetch_fn: retry_fetch_fn, poll_interval: 60_000)

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      ref = Process.monitor(streamer_pid)
      Streamer.subscribe_pid(streamer_pid, subscriber)

      assert_receive :fetch_called, 1_000
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^streamer_pid, :normal}, 2_000
    end

    test "multiple subscribers — streamer stays alive until all leave" do
      test_pid = self()

      retry_fetch_fn = fn _app, _opts ->
        send(test_pid, :fetch_called)
        {:ok, []}
      end

      %{pid: streamer_pid} =
        start_streamer(retry_fetch_fn: retry_fetch_fn, poll_interval: 60_000)

      sub1 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      sub2 =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      Streamer.subscribe_pid(streamer_pid, sub1)
      Streamer.subscribe_pid(streamer_pid, sub2)

      assert_receive :fetch_called, 1_000
      ref = Process.monitor(streamer_pid)

      Process.exit(sub1, :kill)
      refute_receive {:DOWN, ^ref, :process, ^streamer_pid, _}, 300

      Process.exit(sub2, :kill)
      assert_receive {:DOWN, ^ref, :process, ^streamer_pid, :normal}, 2_000
    end
  end

  describe "StreamerSupervisor integration" do
    test "start_streamer registers and stop_streamer removes" do
      app_name = "sup-app-#{System.unique_integer([:positive])}"
      refute StreamerSupervisor.streamer_running?(app_name)

      retry_fetch_fn = fn _app, _opts -> {:ok, []} end

      {:ok, _} =
        StreamerSupervisor.start_streamer(app_name, "/tmp/test",
          retry_fetch_fn: retry_fetch_fn,
          poll_interval: 60_000
        )

      assert StreamerSupervisor.streamer_running?(app_name)

      [{pid, _}] = Registry.lookup(StreamerSupervisor.registry_name(), app_name)
      ref = Process.monitor(pid)
      StreamerSupervisor.stop_streamer(app_name)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      Enum.reduce_while(1..20, nil, fn _, _ ->
        if StreamerSupervisor.streamer_running?(app_name) do
          Process.sleep(10)
          {:cont, nil}
        else
          {:halt, :done}
        end
      end)

      refute StreamerSupervisor.streamer_running?(app_name)
    end

    test "start_streamer returns error if already running" do
      app_name = "dup-app-#{System.unique_integer([:positive])}"
      retry_fetch_fn = fn _app, _opts -> {:ok, []} end

      {:ok, _} =
        StreamerSupervisor.start_streamer(app_name, "/tmp/test",
          retry_fetch_fn: retry_fetch_fn,
          poll_interval: 60_000
        )

      assert {:error, :already_running} =
               StreamerSupervisor.start_streamer(app_name, "/tmp/test",
                 retry_fetch_fn: retry_fetch_fn,
                 poll_interval: 60_000
               )

      StreamerSupervisor.stop_streamer(app_name)
    end
  end

  describe "subscribe/3 silent-failure path (M3)" do
    test "returns {:error, :no_streamer} when no registry is provided" do
      # No :registry opt — the cond falls through the is_nil(registry) branch.
      # Old behavior: silently :ok with no messages ever arriving.
      assert {:error, :no_streamer} =
               Streamer.subscribe("some-app", "/tmp/test", [])
    end

    test "returns {:error, :no_streamer} when registry lookup misses and no dynamic_sup" do
      # Registry is set but has no entry for this app, and no dynamic_sup was
      # passed — there is nothing to start the streamer.
      registry = StreamerSupervisor.registry_name()

      assert {:error, :no_streamer} =
               Streamer.subscribe(
                 "unregistered-app-#{System.unique_integer([:positive])}",
                 "/tmp/test",
                 registry: registry
               )
    end
  end

  describe "error handling" do
    test "handles fetch errors without crashing" do
      test_pid = self()
      call_count = :counters.new(1, [:atomics])

      retry_fetch_fn = fn _app, _opts ->
        count = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, count)
        send(test_pid, {:fetch_called, count})

        if count == 1, do: {:error, :timeout}, else: {:ok, []}
      end

      %{pid: streamer_pid} =
        start_streamer(retry_fetch_fn: retry_fetch_fn, poll_interval: 50)

      assert_receive {:fetch_called, 1}, 1_000
      assert Process.alive?(streamer_pid)

      assert_receive {:fetch_called, 2}, 1_000
      assert Process.alive?(streamer_pid)
    end
  end
end
