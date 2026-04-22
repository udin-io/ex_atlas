defmodule ExAtlas.Fly.TokensTest do
  @moduledoc """
  Exercises the `ExAtlas.Fly.Tokens` facade end-to-end against a per-test
  instance of the `ExAtlas.Fly.Tokens.Supervisor` trio. The facade dispatches
  via `Application.get_env(:ex_atlas, :fly_tokens_names, %{})`, which each
  test sets up + tears down in setup/on_exit.

  Migrated from the pre-E1 `server_test.exs` — the old tests called
  `Tokens.Server.get_token/2` directly with a per-test process name. After
  the per-app split they route through the facade; the AppServer resolves
  lazily on first call.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Fly.Tokens
  alias ExAtlas.Fly.Tokens.AppServer
  alias ExAtlas.Fly.Tokens.Supervisor, as: TokensSupervisor
  alias ExAtlas.Fly.TokenStorage.Memory
  alias ExAtlas.Fly.TokenStorage.Raising

  @app_name "my-fly-app"
  @token "FlyV1 fm2_test_token_abc123"
  @ttl_seconds 24 * 60 * 60

  setup do
    start_supervised!(Memory)

    unique = System.unique_integer([:positive])

    names = %{
      supervisor: :"tokens_sup_#{unique}",
      registry: :"tokens_registry_#{unique}",
      ets_owner: :"tokens_ets_owner_#{unique}",
      dynamic_sup: :"tokens_dyn_sup_#{unique}",
      task_sup: :"tokens_task_sup_#{unique}",
      ets_table: :"tokens_ets_#{unique}"
    }

    {:ok, %{names: names, unique: unique}}
  end

  # Boot a per-test Supervisor trio and configure the facade to route to it
  # via the :fly_tokens_names Application env override. Any AppServer
  # resolved through the facade inherits the test's cmd_fn/config_file_fn
  # /storage_mod/cli_timeout_ms from :app_server_defaults.
  defp start_tokens_trio(context, opts \\ []) do
    cmd_fn = Keyword.get(opts, :cmd_fn, fn _cmd, _args, _opts -> {"", 1} end)
    config_file_fn = Keyword.get(opts, :config_file_fn, fn -> :miss end)
    storage_mod = Keyword.get(opts, :storage_mod, Memory)
    cli_timeout_ms = Keyword.get(opts, :cli_timeout_ms, 500)

    app_server_defaults = [
      cmd_fn: cmd_fn,
      config_file_fn: config_file_fn,
      storage_mod: storage_mod,
      cli_timeout_ms: cli_timeout_ms
    ]

    previous = Application.get_env(:ex_atlas, :fly_tokens_names)

    Application.put_env(:ex_atlas, :fly_tokens_names, %{
      registry: context.names.registry,
      dynamic_sup: context.names.dynamic_sup,
      ets_owner: context.names.ets_owner,
      task_sup: context.names.task_sup,
      ets_table: context.names.ets_table,
      app_server_defaults: app_server_defaults
    })

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ex_atlas, :fly_tokens_names)
        _ -> Application.put_env(:ex_atlas, :fly_tokens_names, previous)
      end
    end)

    {:ok, pid} =
      start_supervised(
        {TokensSupervisor,
         [
           name: context.names.supervisor,
           registry: context.names.registry,
           ets_owner: context.names.ets_owner,
           dynamic_sup: context.names.dynamic_sup,
           task_sup: context.names.task_sup,
           ets_table: context.names.ets_table
         ]},
        id: context.names.supervisor
      )

    pid
  end

  defp expire_token(context, app_name) do
    pid = TokensSupervisor.whereis_app_server(app_name, registry: context.names.registry)
    refute is_nil(pid), "expected an AppServer for #{app_name} to be running"
    GenServer.call(pid, :expire_token)
  end

  describe "Tokens.get/1 cache miss → CLI acquisition" do
    test "acquires token via CLI when cache and storage are empty", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
    end

    test "stores acquired token in ETS for subsequent reads", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
      assert {:ok, @token} = Tokens.get(@app_name)
    end

    test "persists acquired token in TokenStorage", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
      assert {:ok, %{token: @token, expires_at: expires_at}} = Memory.get(@app_name, :cached)
      assert is_integer(expires_at)
    end
  end

  describe "Tokens.get/1 cache hit" do
    test "returns cached token without CLI call", context do
      call_count = :counters.new(1, [:atomics])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        :counters.add(call_count, 1, 1)
        {@token, 0}
      end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
      assert :counters.get(call_count, 1) == 1

      assert {:ok, @token} = Tokens.get(@app_name)
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "Tokens.get/1 token expiry" do
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

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)

      expire_token(context, @app_name)

      assert {:ok, ^new_token} = Tokens.get(@app_name)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "Tokens.get/1 storage restoration" do
    test "restores token from storage when ETS is empty but storage has valid token",
         context do
      expires_at = System.system_time(:second) + @ttl_seconds
      Memory.put(@app_name, :cached, %{token: @token, expires_at: expires_at})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        raise "CLI should not be called when storage has valid token"
      end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
    end

    test "skips expired storage token and acquires via CLI", context do
      expires_at = System.system_time(:second) - 100
      Memory.put(@app_name, :cached, %{token: "old-expired-token", expires_at: expires_at})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
    end
  end

  describe "Tokens.get/1 CLI failure → manual token fallback" do
    test "falls back to manual token when CLI fails", context do
      manual_token = "FlyV1 fm2_manual_token"
      Memory.put(@app_name, :manual, %{token: manual_token, expires_at: nil})

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: could not find flyctl", 1}
      end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, ^manual_token} = Tokens.get(@app_name)
    end

    test "returns error when CLI fails and no manual token exists", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: not authenticated", 1}
      end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:error, :no_token_available} = Tokens.get(@app_name)
    end
  end

  describe "Tokens.get/1 CLI timeout" do
    test "handles CLI timeout gracefully", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        Process.sleep(:infinity)
      end

      start_tokens_trio(context, cmd_fn: cmd_fn, cli_timeout_ms: 100)

      assert {:error, :no_token_available} = Tokens.get(@app_name)
    end
  end

  describe "Tokens.invalidate/1" do
    test "removes token from ETS cache", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)
      assert :ok = Tokens.invalidate(@app_name)
      assert :ets.lookup(context.names.ets_table, @app_name) == []
    end

    test "is a cheap :ok no-op for unknown apps", context do
      start_tokens_trio(context)

      assert :ok = Tokens.invalidate("never-resolved-app-#{context.unique}")

      # Should not have booted an AppServer for the unknown app.
      assert nil ==
               TokensSupervisor.whereis_app_server("never-resolved-app-#{context.unique}",
                 registry: context.names.registry
               )
    end
  end

  describe "config file resolution" do
    test "resolves token from config file when ETS and storage miss", context do
      config_token = "FlyV1 fm2_config_file_token"
      config_file_fn = fn -> {:ok, config_token} end

      start_tokens_trio(context, config_file_fn: config_file_fn)

      assert {:ok, ^config_token} = Tokens.get(@app_name)
    end

    test "caches config file token in ETS after first read", context do
      config_token = "FlyV1 fm2_config_cached"
      call_count = :counters.new(1, [:atomics])

      config_file_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, config_token}
      end

      start_tokens_trio(context, config_file_fn: config_file_fn)

      assert {:ok, ^config_token} = Tokens.get(@app_name)
      assert :counters.get(call_count, 1) == 1

      assert {:ok, ^config_token} = Tokens.get(@app_name)
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

        start_tokens_trio(context, config_file_fn: config_file_fn, cmd_fn: cmd_fn)

        assert {:error, :no_token_available} = Tokens.get(@app_name)
      after
        Application.put_env(:ex_atlas, :fly, previous)
      end
    end
  end

  describe "Tokens.set_manual/2" do
    test "stores manual token in storage", context do
      manual_token = "FlyV1 fm2_user_provided"

      start_tokens_trio(context)

      assert :ok = Tokens.set_manual(@app_name, manual_token)
      assert {:ok, %{token: ^manual_token, expires_at: nil}} = Memory.get(@app_name, :manual)
    end

    test "manual token is used when CLI is unavailable", context do
      manual_token = "FlyV1 fm2_user_provided"

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        {"Error: flyctl not found", 1}
      end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert :ok = Tokens.set_manual(@app_name, manual_token)
      assert {:ok, ^manual_token} = Tokens.get(@app_name)
    end
  end

  describe "telemetry (N6a)" do
    @acquire_event [:ex_atlas, :fly, :token, :acquire]

    defp attach_telemetry(handler_id, events) do
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end

      :telemetry.attach_many(handler_id, events, handler, nil)
      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "emits :start and :stop with source=:cli + acquirer=:app_server on fresh acquire",
         context do
      attach_telemetry("token-cli-#{context.unique}", [
        @acquire_event ++ [:start],
        @acquire_event ++ [:stop]
      ])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end
      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:ok, @token} = Tokens.get(@app_name)

      start_event = @acquire_event ++ [:start]
      stop_event = @acquire_event ++ [:stop]

      assert_receive {:telemetry, ^start_event, %{system_time: _}, %{app: @app_name}}, 500
      assert_receive {:telemetry, ^stop_event, %{duration: _}, meta}, 500
      assert meta.app == @app_name
      assert meta.source == :cli
      assert meta.acquirer == :app_server
    end

    test "emits :stop with source=:ets + acquirer=:facade on fast-path cache hit", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end
      start_tokens_trio(context, cmd_fn: cmd_fn)

      # Prime the cache.
      assert {:ok, @token} = Tokens.get(@app_name)

      # Now attach and fetch — must hit ETS in the facade, without touching
      # the AppServer mailbox. That's what :acquirer == :facade proves.
      attach_telemetry("token-ets-#{context.unique}", [@acquire_event ++ [:stop]])

      assert {:ok, @token} = Tokens.get(@app_name)

      stop_event = @acquire_event ++ [:stop]
      assert_receive {:telemetry, ^stop_event, _measurements, meta}, 500
      assert meta.source == :ets
      assert meta.acquirer == :facade
    end

    test "emits :stop with source=:config when config file resolves", context do
      attach_telemetry("token-config-#{context.unique}", [@acquire_event ++ [:stop]])

      config_token = "FlyV1 fm2_config_file_token"
      config_file_fn = fn -> {:ok, config_token} end

      start_tokens_trio(context, config_file_fn: config_file_fn)

      assert {:ok, ^config_token} = Tokens.get(@app_name)

      stop_event = @acquire_event ++ [:stop]
      assert_receive {:telemetry, ^stop_event, _measurements, meta}, 500
      assert meta.source == :config
    end

    test "emits :stop with source=:none when resolution fails", context do
      attach_telemetry("token-none-#{context.unique}", [@acquire_event ++ [:stop]])

      cmd_fn = fn _, _, _ -> {"Error: not authenticated", 1} end
      start_tokens_trio(context, cmd_fn: cmd_fn)

      assert {:error, :no_token_available} = Tokens.get(@app_name)

      stop_event = @acquire_event ++ [:stop]
      assert_receive {:telemetry, ^stop_event, _measurements, meta}, 500
      assert meta.source == :none
    end
  end

  describe "persist failures (H2)" do
    test "CLI-acquired token is still returned when storage put fails", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn, storage_mod: Raising)

      log =
        capture_log(fn ->
          assert {:ok, @token} = Tokens.get(@app_name)
          # Persist runs in a Task under the per-test Task.Supervisor —
          # wait until it finishes so its :error log lands inside the
          # capture_log window.
          await_task_sup_drain(context)
        end)

      # Error-level log (not merely warning) so operators catch silent data loss.
      assert log =~ "[error]"
      assert log =~ "persist"
      assert log =~ @app_name
    end

    test "config-file-sourced token is still returned when storage put fails", context do
      config_file_fn = fn -> {:ok, @token} end

      start_tokens_trio(context,
        config_file_fn: config_file_fn,
        storage_mod: Raising
      )

      log =
        capture_log(fn ->
          assert {:ok, @token} = Tokens.get(@app_name)
          await_task_sup_drain(context)
        end)

      assert log =~ "[error]"
      assert log =~ "persist"
    end

    test "set_manual surfaces storage failure as {:error, reason}", context do
      manual_token = "FlyV1 fm2_user_provided"

      start_tokens_trio(context, storage_mod: Raising)

      # Manual-token put goes directly to storage; failure must be surfaced,
      # not silently swallowed — manual tokens are NOT re-acquirable.
      assert {:error, _reason} = Tokens.set_manual(@app_name, manual_token)
    end
  end

  describe "E1 per-app split (proof of fix)" do
    test "concurrent get for two apps runs CLIs in parallel", context do
      # Each CLI call sleeps 300ms. If the pre-E1 serialized model still
      # reigned, two apps' get calls would take ≥ 600ms. Per-app split
      # lets them run in parallel, so elapsed should be well under 500ms.
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        Process.sleep(300)
        {@token, 0}
      end

      # Generous server-side budget so the 300ms CLI sleep fits comfortably.
      start_tokens_trio(context, cmd_fn: cmd_fn, cli_timeout_ms: 5_000)

      {elapsed_us, _results} =
        :timer.tc(fn ->
          t1 = Task.async(fn -> Tokens.get("app-one-#{context.unique}") end)
          t2 = Task.async(fn -> Tokens.get("app-two-#{context.unique}") end)
          Task.await_many([t1, t2], 5_000)
        end)

      elapsed_ms = div(elapsed_us, 1_000)

      assert elapsed_ms < 500,
             "Expected parallel CLI acquisition (<500ms), took #{elapsed_ms}ms. " <>
               "Serialized behavior (pre-E1) would be ≥600ms."
    end

    test "concurrent get for same app calls CLI exactly once", context do
      call_count = :counters.new(1, [:atomics])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        :counters.add(call_count, 1, 1)
        # Small sleep so later callers pile into the same mailbox.
        Process.sleep(100)
        {@token, 0}
      end

      start_tokens_trio(context, cmd_fn: cmd_fn, cli_timeout_ms: 5_000)

      app = "same-app-#{context.unique}"

      tasks = for _ <- 1..10, do: Task.async(fn -> Tokens.get(app) end)
      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, &match?({:ok, @token}, &1))

      # Exactly one CLI call proves coalescing works — the second through
      # tenth callers pile into the same AppServer mailbox, then re-check
      # ETS (filled by the first) in handle_call.
      assert :counters.get(call_count, 1) == 1
    end

    test "AppServer crash preserves cached token in ETS", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      # Prime the cache.
      assert {:ok, @token} = Tokens.get(@app_name)

      pid = TokensSupervisor.whereis_app_server(@app_name, registry: context.names.registry)
      refute is_nil(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      # Wait until DynamicSupervisor has re-started the AppServer.
      wait_until(fn ->
        new_pid =
          TokensSupervisor.whereis_app_server(@app_name, registry: context.names.registry)

        is_pid(new_pid) and new_pid != pid
      end)

      # ETS is owned by ETSOwner, which did NOT crash — cached token survives.
      # A subsequent get resolves from ETS without hitting the cmd_fn, which
      # we prove by supplying a cmd_fn that now raises.
      Application.put_env(:ex_atlas, :fly_tokens_names, %{
        registry: context.names.registry,
        dynamic_sup: context.names.dynamic_sup,
        ets_owner: context.names.ets_owner,
        task_sup: context.names.task_sup,
        ets_table: context.names.ets_table,
        app_server_defaults: [
          cmd_fn: fn _, _, _ ->
            raise "CLI should not be called; ETS should still have the token"
          end,
          config_file_fn: fn -> :miss end,
          storage_mod: Memory,
          cli_timeout_ms: 500
        ]
      })

      assert {:ok, @token} = Tokens.get(@app_name)
    end

    test "ETSOwner crash wipes ETS but AppServers recover on next get", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      # Prime the cache.
      assert {:ok, @token} = Tokens.get(@app_name)
      assert [_] = :ets.lookup(context.names.ets_table, @app_name)

      # Also seed storage so recovery has a :storage source path rather than
      # needing the (still-configured) CLI.
      expires_at = System.system_time(:second) + @ttl_seconds
      Memory.put(@app_name, :cached, %{token: @token, expires_at: expires_at})

      ets_owner = Process.whereis(context.names.ets_owner)
      refute is_nil(ets_owner)

      ref = Process.monitor(ets_owner)
      Process.exit(ets_owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^ets_owner, _}, 1_000

      # :rest_for_one rebuilds ETSOwner AND the DynamicSupervisor (wiping all
      # AppServers). Wait until the new ETSOwner is up with a fresh table.
      wait_until(fn ->
        owner = Process.whereis(context.names.ets_owner)
        is_pid(owner) and :ets.whereis(context.names.ets_table) != :undefined
      end)

      # Table is fresh — nothing in it.
      assert :ets.lookup(context.names.ets_table, @app_name) == []

      # Next get fills the cache from Memory storage (not from CLI, because
      # Memory still has the seeded entry).
      assert {:ok, @token} = Tokens.get(@app_name)
    end
  end

  # Wait for the per-test Task.Supervisor to have zero children — used by
  # persist-failure tests to ensure the async persist task has completed
  # (and emitted its :error log) before capture_log/1 returns.
  defp await_task_sup_drain(context) do
    wait_until(fn ->
      Task.Supervisor.children(context.names.task_sup) == []
    end)
  end

  # Polls `fun` every 20ms up to ~1s. Fails the test on timeout.
  defp wait_until(fun) do
    Enum.reduce_while(1..50, :timeout, fn _, acc ->
      if fun.() do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, acc}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("wait_until timed out")
    end
  end

  describe "soft-expiry refresh (E7)" do
    test "proactively re-resolves cache before expiry (fires without a caller)" do
      unique = System.unique_integer([:positive])

      names = %{
        supervisor: :"e7_sup_#{unique}",
        registry: :"e7_reg_#{unique}",
        ets_owner: :"e7_eo_#{unique}",
        dynamic_sup: :"e7_ds_#{unique}",
        task_sup: :"e7_ts_#{unique}",
        ets_table: :"e7_table_#{unique}"
      }

      # Memory is already started by the top-level setup.
      test_pid = self()

      call_count = :counters.new(1, [:atomics])

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts ->
        :counters.add(call_count, 1, 1)
        send(test_pid, {:cli_called, :counters.get(call_count, 1)})
        {@token <> "-#{:counters.get(call_count, 1)}", 0}
      end

      previous = Application.get_env(:ex_atlas, :fly_tokens_names)

      Application.put_env(:ex_atlas, :fly_tokens_names, %{
        registry: names.registry,
        dynamic_sup: names.dynamic_sup,
        ets_owner: names.ets_owner,
        task_sup: names.task_sup,
        ets_table: names.ets_table,
        app_server_defaults: [
          cmd_fn: cmd_fn,
          config_file_fn: fn -> :miss end,
          storage_mod: Memory,
          cli_timeout_ms: 500,
          # TTL 2s, soft-expiry lead 1s → refresh timer fires at t+1s.
          ttl_seconds: 2,
          soft_expiry_lead_seconds: 1
        ]
      })

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:ex_atlas, :fly_tokens_names)
          _ -> Application.put_env(:ex_atlas, :fly_tokens_names, previous)
        end
      end)

      start_supervised!(
        {TokensSupervisor,
         [
           name: names.supervisor,
           registry: names.registry,
           ets_owner: names.ets_owner,
           dynamic_sup: names.dynamic_sup,
           task_sup: names.task_sup,
           ets_table: names.ets_table
         ]}
      )

      app = "e7-app-#{unique}"

      # First acquire → CLI runs, :cached written to Memory + ETS.
      assert {:ok, _token1} = Tokens.get(app)
      assert_receive {:cli_called, 1}, 1_000

      # Invalidate storage (but NOT ETS) so the scheduled soft-expiry will
      # fall through to CLI when it fires. The ETS entry will be deleted
      # by the handle_info itself.
      Memory.delete(app, :cached)

      # Wait for soft-expiry (1s after first acquire) to fire.
      # CLI should be invoked a second time (ETS gone after handle_info
      # deletes it, storage gone because we just deleted, config_file :miss
      # → CLI path).
      assert_receive {:cli_called, 2}, 2_000
    end
  end

  describe "Tokens.refresh/1 (E5)" do
    test "invalidates ETS and returns a fresh token via the resolution chain", context do
      # The spec of refresh/1: after refresh, the returned token is the
      # result of running the full resolve_token chain with ETS pre-cleared.
      # If storage has a valid cached token, refresh returns it (source:
      # :storage); if storage is empty, the CLI is called.
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn, storage_mod: Memory)

      assert {:ok, @token} = Tokens.get(@app_name)

      # Ensure async persist to Memory completed, otherwise refresh might
      # race with it and see an empty storage → CLI source.
      await_task_sup_drain(context)

      # Refresh after storage was populated: ETS cleared, storage hit.
      assert {:ok, @token} = Tokens.refresh(@app_name)

      # Subsequent get hits ETS (re-filled by the :storage branch in refresh).
      assert {:ok, @token} = Tokens.get(@app_name)
    end

    test "emits telemetry acquirer=:app_server and valid source", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end
      start_tokens_trio(context, cmd_fn: cmd_fn)

      # Prime (writes to Memory via async persist) and then attach so we only
      # catch the refresh event.
      assert {:ok, @token} = Tokens.get(@app_name)
      await_task_sup_drain(context)

      test_pid = self()

      :telemetry.attach(
        "refresh-#{context.unique}",
        [:ex_atlas, :fly, :token, :acquire, :stop],
        fn _e, m, meta, _ -> send(test_pid, {:stop, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("refresh-#{context.unique}") end)

      assert {:ok, _} = Tokens.refresh(@app_name)

      assert_receive {:stop, _, meta}, 500
      assert meta.app == @app_name
      assert meta.acquirer == :app_server
      # Source is whatever the chain produced — storage (if seeded) or cli.
      assert meta.source in [:storage, :cli]
    end
  end

  describe "config M8/M9 (init-time resolution)" do
    test "fly_config_file_enabled snapshot is taken at AppServer init", context do
      # AppServer resolves :fly_config_file_enabled once at its init, not on
      # every handle_call. That means changing the env AFTER the AppServer
      # has started does NOT affect the already-initialized process.
      #
      # Validate by: set env=false → make first Tokens.get (AppServer inits,
      # captures false) → flip env=true at runtime → next get still behaves
      # as if config file is disabled.
      previous = Application.get_env(:ex_atlas, :fly, [])

      try do
        Application.put_env(
          :ex_atlas,
          :fly,
          Keyword.put(previous, :fly_config_file_enabled, false)
        )

        call_count = :counters.new(1, [:atomics])

        config_file_fn = fn ->
          :counters.add(call_count, 1, 1)
          {:ok, "from-config-file"}
        end

        cmd_fn = fn _, _, _ -> {@token, 0} end

        start_tokens_trio(context, config_file_fn: config_file_fn, cmd_fn: cmd_fn)

        # First get → AppServer lazy-starts with config_file_enabled: false.
        # config_file_fn is skipped, cmd_fn runs → :cli source.
        assert {:ok, @token} = Tokens.get(@app_name)
        assert :counters.get(call_count, 1) == 0

        # Flip env at runtime — the existing AppServer already snapshotted.
        Application.put_env(
          :ex_atlas,
          :fly,
          Keyword.put(previous, :fly_config_file_enabled, true)
        )

        # Invalidate ETS + storage to force a fresh resolve path.
        :ok = Tokens.invalidate(@app_name)

        assert {:ok, _} = Tokens.get(@app_name)
        # Still zero — snapshot is honored despite the runtime env flip.
        assert :counters.get(call_count, 1) == 0
      after
        Application.put_env(:ex_atlas, :fly, previous)
      end
    end
  end

  describe "H3 async persist (proof of fix)" do
    # A slow-put storage that reports the put call but blocks for `delay_ms`
    # before returning. Used to show that the AppServer reply is not gated
    # on the storage write.
    defmodule SlowStorage do
      @behaviour ExAtlas.Fly.TokenStorage

      @impl true
      def child_spec(_opts),
        do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker}

      def start_link, do: Agent.start_link(fn -> nil end, name: __MODULE__)

      @impl true
      def get(_, _), do: :error

      @impl true
      def put(app, _key, _record) do
        delay = Application.get_env(:ex_atlas, :slow_storage_delay_ms, 300)
        test_pid = Application.get_env(:ex_atlas, :slow_storage_test_pid)
        if test_pid, do: send(test_pid, {:slow_put_started, app})
        Process.sleep(delay)
        if test_pid, do: send(test_pid, {:slow_put_finished, app})
        :ok
      end

      @impl true
      def delete(_, _), do: :ok
    end

    test "AppServer replies before storage put completes (cached path)", context do
      # Tell SlowStorage to report its start/finish to us.
      Application.put_env(:ex_atlas, :slow_storage_delay_ms, 300)
      Application.put_env(:ex_atlas, :slow_storage_test_pid, self())

      on_exit(fn ->
        Application.delete_env(:ex_atlas, :slow_storage_delay_ms)
        Application.delete_env(:ex_atlas, :slow_storage_test_pid)
      end)

      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn, storage_mod: SlowStorage)

      # Measure how long Tokens.get takes. With async persist the reply is
      # gated only on ETS write + cmd_fn, NOT on the 300ms storage put.
      {elapsed_us, {:ok, @token}} = :timer.tc(fn -> Tokens.get(@app_name) end)
      elapsed_ms = div(elapsed_us, 1_000)

      # Budget: storage put sleeps 300ms. Async persist should return well
      # under that. Generous slack (200ms) absorbs CI / loaded-machine noise
      # while still catching a regression to synchronous persist.
      assert elapsed_ms < 200,
             "Expected async persist (<200ms), got #{elapsed_ms}ms. " <>
               "Synchronous persist would be ≥300ms."

      # The slow put was still started — confirm it ran in the background.
      assert_receive {:slow_put_started, @app_name}, 500
      # And eventually finishes.
      assert_receive {:slow_put_finished, @app_name}, 2_000
    end

    test "set_manual remains synchronous (caller still sees {:error, _} on failure)", context do
      # Manual-token persist MUST stay sync — manual tokens are not
      # re-acquirable and the caller has to know if persist failed.
      start_tokens_trio(context, storage_mod: Raising)

      assert {:error, {:persist_failed, _reason}} =
               Tokens.set_manual(@app_name, "some-manual-token")
    end
  end

  describe "AppServer direct (internal behavior)" do
    # A sanity check that AppServer's own public API works when called directly —
    # used rarely (test backdoors, diagnostics) but part of the module's
    # contract.
    test "AppServer.acquire/1 returns {{:ok, token}, :cli} on success", context do
      cmd_fn = fn "fly", ["tokens", "create", "readonly"], _opts -> {@token, 0} end

      start_tokens_trio(context, cmd_fn: cmd_fn)

      {:ok, pid} =
        TokensSupervisor.resolve_app_server(@app_name,
          registry: context.names.registry,
          dynamic_sup: context.names.dynamic_sup,
          task_sup: context.names.task_sup,
          ets_table: context.names.ets_table,
          app_server_defaults: [
            cmd_fn: cmd_fn,
            config_file_fn: fn -> :miss end,
            storage_mod: Memory,
            cli_timeout_ms: 500
          ]
        )

      assert {{:ok, @token}, :cli} = AppServer.acquire(pid)
    end
  end
end
