defmodule ExAtlas.Fly.TokenStorage.MemoryTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Fly.TokenStorage.Memory

  # The E2 conformance suite covers the full get/put/delete contract across
  # :cached and :manual keys for every TokenStorage implementation.
  use ExAtlas.Fly.TokenStorageConformance,
    storage: ExAtlas.Fly.TokenStorage.Memory,
    setup: {__MODULE__, :__setup_memory__, []}

  @doc false
  def __setup_memory__ do
    if pid = Process.whereis(Memory), do: GenServer.stop(pid)
    {:ok, _} = Memory.start_link()
    :ok
  end

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
end
