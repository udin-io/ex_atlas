defmodule ExAtlas.Fly.Tokens.ServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Fly.Tokens.Server
  alias ExAtlas.Fly.TokenStorage.Memory
  alias ExAtlas.Fly.TokenStorage.Raising

  @app_name "my-fly-app"
  @token "FlyV1 fm2_test_token_abc123"
  @ttl_seconds 24 * 60 * 60

  setup do
    start_supervised!(Memory)

    test_name = :"ex_atlas_fly_tokens_#{System.unique_integer([:positive])}"
    table_name = :"#{test_name}_ets"

    %{test_name: test_name, table_name: table_name}
  end

  defp start_server(context, opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, fn _cmd, _args, _opts -> {"", 1} end)

    server_opts = [
      name: context.test_name,
      table_name: context.table_name,
      cmd_fn: cmd_fn,
      storage_mod: Memory,
      config_file_fn: Keyword.get(opts, :config_file_fn, fn -> :miss end),
      cli_timeout_ms: Keyword.get(opts, :cli_timeout_ms, 500)
    ]

    {:ok, pid} = start_supervised({Server, server_opts}, id: context.test_name)
    pid
  end

  describe "get_token/2 cache miss → CLI acquisition" do
    test "acquires token via CLI when cache and storage are empty", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
    end

    test "stores acquired token in ETS for subsequent reads", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
    end

    test "persists acquired token in TokenStorage", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
      assert {:ok, %{token: @token, expires_at: expires_at}} = Memory.get(@app_name, :cached)
      assert is_integer(expires_at)
    end
  end

  describe "get_token/2 cache hit" do
    test "returns cached token without CLI call", context do
      call_count = :counters.new(1, [:atomics])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        :counters.add(call_count, 1, 1)
        {@token, 0}
      end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
      assert :counters.get(call_count, 1) == 1

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "get_token/2 token expiry" do
    test "re-acquires token when cached token is expired", context do
      new_token = "FlyV1 fm2_refreshed_token"
      call_count = :counters.new(1, [:atomics])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        :counters.add(call_count, 1, 1)

        case :counters.get(call_count, 1) do
          1 -> {@token, 0}
          _ -> {new_token, 0}
        end
      end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)

      GenServer.call(context.test_name, {:expire_token, @app_name})

      assert {:ok, ^new_token} = Server.get_token(@app_name, context.test_name)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "get_token/2 storage restoration" do
    test "restores token from storage when ETS is empty but storage has valid token",
         context do
      expires_at = System.system_time(:second) + @ttl_seconds
      Memory.put(@app_name, :cached, %{token: @token, expires_at: expires_at})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        raise "CLI should not be called when storage has valid token"
      end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
    end

    test "skips expired storage token and acquires via CLI", context do
      expires_at = System.system_time(:second) - 100
      Memory.put(@app_name, :cached, %{token: "old-expired-token", expires_at: expires_at})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
    end
  end

  describe "get_token/2 CLI failure → manual token fallback" do
    test "falls back to manual token when CLI fails", context do
      manual_token = "FlyV1 fm2_manual_token"
      Memory.put(@app_name, :manual, %{token: manual_token, expires_at: nil})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: could not find flyctl", 1}
      end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, ^manual_token} = Server.get_token(@app_name, context.test_name)
    end

    test "returns error when CLI fails and no manual token exists", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: not authenticated", 1}
      end

      start_server(context, cmd_fn: cmd_fn)

      assert {:error, :no_token_available} = Server.get_token(@app_name, context.test_name)
    end
  end

  describe "get_token/2 CLI timeout" do
    test "handles CLI timeout gracefully", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        Process.sleep(:infinity)
      end

      start_server(context, cmd_fn: cmd_fn, cli_timeout_ms: 100)

      assert {:error, :no_token_available} = Server.get_token(@app_name, context.test_name)
    end
  end

  describe "invalidate_token/2" do
    test "removes token from ETS cache", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_server(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
      assert :ok = Server.invalidate_token(@app_name, context.test_name)
      assert :ets.lookup(context.table_name, @app_name) == []
    end
  end

  describe "config file resolution" do
    test "resolves token from config file when ETS and storage miss", context do
      config_token = "FlyV1 fm2_config_file_token"
      config_file_fn = fn -> {:ok, config_token} end

      start_server(context, config_file_fn: config_file_fn)

      assert {:ok, ^config_token} = Server.get_token(@app_name, context.test_name)
    end

    test "caches config file token in ETS after first read", context do
      config_token = "FlyV1 fm2_config_cached"
      call_count = :counters.new(1, [:atomics])

      config_file_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, config_token}
      end

      start_server(context, config_file_fn: config_file_fn)

      assert {:ok, ^config_token} = Server.get_token(@app_name, context.test_name)
      assert :counters.get(call_count, 1) == 1

      assert {:ok, ^config_token} = Server.get_token(@app_name, context.test_name)
      assert :counters.get(call_count, 1) == 1
    end

    test "skips config file when fly_config_file_enabled is false", context do
      config_file_fn = fn -> raise "config_file_fn should not be called when disabled" end
      cmd_fn = fn _, _, _ -> {"", 1} end

      previous = Application.get_env(:ex_atlas, :fly, [])

      try do
        Application.put_env(
          :ex_atlas,
          :fly,
          Keyword.put(previous, :fly_config_file_enabled, false)
        )

        start_server(context, config_file_fn: config_file_fn, cmd_fn: cmd_fn)

        assert {:error, :no_token_available} = Server.get_token(@app_name, context.test_name)
      after
        Application.put_env(:ex_atlas, :fly, previous)
      end
    end
  end

  describe "set_manual_token/3" do
    test "stores manual token in storage", context do
      manual_token = "FlyV1 fm2_user_provided"

      start_server(context)

      assert :ok = Server.set_manual_token(@app_name, manual_token, context.test_name)
      assert {:ok, %{token: ^manual_token, expires_at: nil}} = Memory.get(@app_name, :manual)
    end

    test "manual token is used when CLI is unavailable", context do
      manual_token = "FlyV1 fm2_user_provided"

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: flyctl not found", 1}
      end

      start_server(context, cmd_fn: cmd_fn)

      assert :ok = Server.set_manual_token(@app_name, manual_token, context.test_name)
      assert {:ok, ^manual_token} = Server.get_token(@app_name, context.test_name)
    end
  end

  describe "persist failures (H2)" do
    test "CLI-acquired token is still returned when storage put fails", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      # Use raising storage (not Memory) to simulate a persist failure.
      server_opts = [
        name: context.test_name,
        table_name: context.table_name,
        cmd_fn: cmd_fn,
        storage_mod: Raising,
        config_file_fn: fn -> :miss end,
        cli_timeout_ms: 500
      ]

      {:ok, _pid} = start_supervised({Server, server_opts}, id: context.test_name)

      log =
        capture_log(fn ->
          assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
        end)

      # Error-level log (not merely warning) so operators catch silent data loss.
      assert log =~ "[error]"
      assert log =~ "persist"
      assert log =~ @app_name
    end

    test "config-file-sourced token is still returned when storage put fails", context do
      config_file_fn = fn -> {:ok, @token} end

      server_opts = [
        name: context.test_name,
        table_name: context.table_name,
        cmd_fn: fn _, _, _ -> {"", 1} end,
        storage_mod: Raising,
        config_file_fn: config_file_fn,
        cli_timeout_ms: 500
      ]

      {:ok, _pid} = start_supervised({Server, server_opts}, id: context.test_name)

      log =
        capture_log(fn ->
          assert {:ok, @token} = Server.get_token(@app_name, context.test_name)
        end)

      assert log =~ "[error]"
      assert log =~ "persist"
    end

    test "set_manual_token surfaces storage failure as {:error, reason}", context do
      manual_token = "FlyV1 fm2_user_provided"

      server_opts = [
        name: context.test_name,
        table_name: context.table_name,
        cmd_fn: fn _, _, _ -> {"", 1} end,
        storage_mod: Raising,
        config_file_fn: fn -> :miss end,
        cli_timeout_ms: 500
      ]

      {:ok, _pid} = start_supervised({Server, server_opts}, id: context.test_name)

      # Manual-token put goes directly to storage; failure must be surfaced,
      # not silently swallowed — manual tokens are NOT re-acquirable.
      assert {:error, _reason} =
               Server.set_manual_token(@app_name, manual_token, context.test_name)
    end
  end
end
