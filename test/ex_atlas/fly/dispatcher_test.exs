defmodule ExAtlas.Fly.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Fly.Dispatcher

  # Test MFA target used by the :mfa dispatcher mode below.
  # Public so it can be referenced as {MODULE, fun, extra}.
  defmodule Target do
    def ok(topic, message, test_pid) do
      send(test_pid, {:dispatched, topic, message})
      :ok
    end

    def raising(_topic, _message, _test_pid) do
      raise RuntimeError, "user MFA blew up"
    end
  end

  setup do
    previous = Application.get_env(:ex_atlas, :fly, [])
    on_exit(fn -> Application.put_env(:ex_atlas, :fly, previous) end)
    :ok
  end

  describe ":mfa mode" do
    test "delivers message via configured MFA" do
      Application.put_env(:ex_atlas, :fly, dispatcher: {:mfa, {Target, :ok, [self()]}})

      assert :ok = Dispatcher.dispatch("topic-ok", {:hello, 1})

      assert_receive {:dispatched, "topic-ok", {:hello, 1}}, 1_000
    end

    test "a raising MFA does not crash the caller; logs at error level" do
      Application.put_env(:ex_atlas, :fly, dispatcher: {:mfa, {Target, :raising, [self()]}})

      caller = self()

      log =
        capture_log(fn ->
          # Call from the test process itself — if the dispatcher re-raises,
          # the test process dies and the assertion after never runs.
          assert :ok = Dispatcher.dispatch("topic-raise", {:boom, 1})
          send(caller, :still_alive)
        end)

      assert_receive :still_alive, 1_000
      assert log =~ "[error]"
      assert log =~ "dispatcher"
    end
  end

  describe "subscribe_with_backpressure/2 (E6)" do
    test "sends {:ex_atlas_fly_backpressure_evict, topic} when queue exceeds threshold" do
      Application.put_env(:ex_atlas, :fly, dispatcher: :registry)

      topic = "bp-topic-#{System.unique_integer([:positive])}"

      test_pid = self()

      # Spawn a subscriber that accumulates messages but never processes them.
      # It forwards any eviction signal back to the test pid.
      subscriber =
        spawn(fn ->
          Dispatcher.subscribe_with_backpressure(topic, threshold: 5, poll_ms: 50)
          # Tell the test we're ready.
          send(test_pid, :subscriber_ready)
          # Do nothing but wait for the eviction sentinel.
          receive do
            {:ex_atlas_fly_backpressure_evict, ^topic} = msg ->
              send(test_pid, {:evicted, msg})
          end
        end)

      assert_receive :subscriber_ready, 1_000

      # Flood the topic so the subscriber's mailbox exceeds the threshold.
      for i <- 1..20, do: Dispatcher.dispatch(topic, {:msg, i})

      assert_receive {:evicted, {:ex_atlas_fly_backpressure_evict, ^topic}}, 2_000

      # Clean up — kill the subscriber so the watchdog can exit.
      Process.exit(subscriber, :kill)
    end

    test "watchdog exits silently when subscriber dies before eviction" do
      Application.put_env(:ex_atlas, :fly, dispatcher: :registry)
      topic = "bp-clean-exit-#{System.unique_integer([:positive])}"

      test_pid = self()

      subscriber =
        spawn(fn ->
          Dispatcher.subscribe_with_backpressure(topic, threshold: 1_000_000, poll_ms: 20)
          send(test_pid, :subscriber_ready)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :subscriber_ready, 1_000
      Process.exit(subscriber, :kill)

      # No eviction message expected; watchdog should clean up via :DOWN.
      refute_receive {:evicted, _}, 200
    end
  end
end
