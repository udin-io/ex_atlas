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
end
