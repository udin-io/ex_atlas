defmodule ExAtlas.Fly.TokenStorage.MemoryTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Fly.TokenStorage.Memory

  describe "parity with Dets pre-init behavior (M10)" do
    test "get/2 returns :error when the Memory Agent has not been started" do
      # Make sure the Agent is definitely not started. It's not started by the
      # application by default — Memory is test-support only — but be safe.
      if pid = Process.whereis(Memory), do: GenServer.stop(pid)

      assert Process.whereis(Memory) == nil

      # Old behavior: Agent.get exits with :noproc. Dets swallows the
      # equivalent ArgumentError and returns :error; Memory must match.
      assert :error = Memory.get("any-app", :cached)
    end
  end

  describe "round-trip" do
    setup do
      start_supervised!(Memory)
      :ok
    end

    test "put + get" do
      assert :ok = Memory.put("app", :cached, %{token: "t", expires_at: 123})
      assert {:ok, %{token: "t", expires_at: 123}} = Memory.get("app", :cached)
    end

    test "get miss returns :error" do
      assert :error = Memory.get("missing", :cached)
    end

    test "delete removes the entry" do
      Memory.put("app", :manual, %{token: "t", expires_at: nil})
      assert {:ok, _} = Memory.get("app", :manual)

      Memory.delete("app", :manual)
      assert :error = Memory.get("app", :manual)
    end
  end
end
