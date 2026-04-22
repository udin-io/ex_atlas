defmodule ExAtlas.Fly.Tokens.AppServer do
  @moduledoc """
  Per-app Fly-token resolver.

  One `AppServer` process exists per Fly app that has ever been asked for a
  token. The process owns the full resolution chain for its app:

    1. ETS cache re-check (in case a concurrent caller won the race).
    2. `ExAtlas.Fly.TokenStorage` (durable).
    3. `~/.fly/config.yml`.
    4. `fly tokens create readonly` (CLI).
    5. Manual-override token (last-resort storage lookup).

  The shared ETS table is owned by `ExAtlas.Fly.Tokens.ETSOwner`; this server
  writes into it but does not own it. That split is what lets per-app crashes
  stay scoped (DynamicSupervisor `:one_for_one`) while still preserving the
  cache for sibling apps.

  ## Runtime options (for test injection)

    * `:app_name` (required) — the Fly app this server tracks.
    * `:registry` (required) — the `Registry` name used for `{:via, ...}` naming.
    * `:task_sup` — `Task.Supervisor` name used to offload non-blocking
      persist writes. Optional; when omitted, persist runs inline (synchronous)
      which is fine for tests without a Task.Supervisor in scope.
    * `:table_name` — override the ETS table to write into.
    * `:cmd_fn` — replaces `System.cmd/3`.
    * `:config_file_fn` — replaces the `~/.fly/config.yml` reader.
    * `:storage_mod` — replaces the storage module.
    * `:ttl_seconds` — token TTL (default 24h).
    * `:cli_timeout_ms` — `fly tokens create` timeout (default 15s).
    * `:soft_expiry_lead_seconds` — how far before `expires_at` to schedule
      a background refresh (default 3600). Set to `0` to disable.
  """

  use GenServer

  require Logger

  @default_table :ex_atlas_fly_tokens
  @default_ttl_seconds 24 * 60 * 60
  @default_cli_timeout_ms 15_000
  # E7: refresh cached tokens when they're within this window of expiry.
  # 1h lead time gives the CLI plenty of slack even under load.
  @default_soft_expiry_lead_seconds 60 * 60

  def start_link(opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    registry = Keyword.fetch!(opts, :registry)

    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {registry, app_name}})
  end

  @doc "Resolve a token for this AppServer's app. Returns `{result, source}`."
  @spec acquire(pid()) ::
          {{:ok, String.t()}, atom()} | {{:error, :no_token_available}, :none}
  def acquire(pid) do
    timeout = cli_timeout_ms() + 5_000
    GenServer.call(pid, :acquire_token, timeout)
  end

  @doc "Invalidate this AppServer's ETS entry."
  @spec invalidate(pid()) :: :ok
  def invalidate(pid), do: GenServer.call(pid, :invalidate)

  @doc """
  Atomic invalidate-then-acquire. Equivalent to `invalidate/1` followed by
  `acquire/1`, but executed under a single handle_call so no concurrent caller
  can acquire between the two and see the pre-refresh token.

  Returns the same `{result, source}` tuple as `acquire/1`.
  """
  @spec refresh(pid()) ::
          {{:ok, String.t()}, atom()} | {{:error, :no_token_available}, :none}
  def refresh(pid) do
    timeout = cli_timeout_ms() + 5_000
    GenServer.call(pid, :refresh_token, timeout)
  end

  @doc """
  Persist a manual-override token for this AppServer's app.

  Returns `{:error, {:persist_failed, reason}}` if the storage backend raises —
  manual tokens are not re-acquirable, so the failure is surfaced rather than
  silently logged.
  """
  @spec set_manual(pid(), String.t()) ::
          :ok | {:error, {:persist_failed, String.t()}}
  def set_manual(pid, token), do: GenServer.call(pid, {:set_manual, token})

  # ── Server callbacks ──

  @impl GenServer
  def init(opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    fly_config = Application.get_env(:ex_atlas, :fly, [])

    state = %{
      app_name: app_name,
      table_name: Keyword.get(opts, :table_name, @default_table),
      task_sup: Keyword.get(opts, :task_sup),
      cmd_fn: Keyword.get(opts, :cmd_fn, &System.cmd/3),
      config_file_fn: Keyword.get(opts, :config_file_fn, &default_config_file_fn/0),
      storage_mod:
        Keyword.get(
          opts,
          :storage_mod,
          Keyword.get(fly_config, :token_storage, ExAtlas.Fly.TokenStorage.Dets)
        ),
      ttl_seconds: Keyword.get(opts, :ttl_seconds, @default_ttl_seconds),
      cli_timeout_ms:
        Keyword.get(
          opts,
          :cli_timeout_ms,
          Keyword.get(fly_config, :cli_timeout_ms, @default_cli_timeout_ms)
        ),
      # M8: resolve :fly_config_file_enabled once at init rather than on every
      # handle_call. Also follows M9's `Keyword.get/3`-with-default style
      # instead of the old case + pattern match on nil.
      config_file_enabled: Keyword.get(fly_config, :fly_config_file_enabled, true),
      soft_expiry_lead_seconds:
        Keyword.get(opts, :soft_expiry_lead_seconds, @default_soft_expiry_lead_seconds),
      soft_expiry_ref: nil
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:acquire_token, _from, state) do
    now = System.system_time(:second)

    # Re-check ETS before descending into the resolve chain — if a concurrent
    # caller filled the cache while we sat in the mailbox, coalesce to that
    # result instead of doing the CLI a second time.
    reply =
      case ets_lookup(state.table_name, state.app_name, now) do
        {:ok, token} -> {{:ok, token}, :ets}
        :miss -> resolve_token(now, state)
      end

    {:reply, reply, maybe_schedule_soft_expiry(state, reply, now)}
  end

  def handle_call(:invalidate, _from, state) do
    :ets.delete(state.table_name, state.app_name)
    {:reply, :ok, state}
  end

  # E5: atomic invalidate-then-acquire. Drops any cached token then runs the
  # full resolution chain — no other caller can win a GenServer.call in
  # between since we're inside a single handle_call.
  def handle_call(:refresh_token, _from, state) do
    :ets.delete(state.table_name, state.app_name)
    now = System.system_time(:second)
    reply = resolve_token(now, state)
    {:reply, reply, maybe_schedule_soft_expiry(state, reply, now)}
  end

  def handle_call({:set_manual, token}, _from, state) do
    # Manual tokens are NOT re-acquirable — never silently swallow a
    # persist failure here.
    result =
      try do
        state.storage_mod.put(state.app_name, :manual, %{token: token, expires_at: nil})
        :ok
      rescue
        e ->
          reason = Exception.message(e)

          Logger.error(
            "[ExAtlas.Fly.Tokens] manual token persist failed for #{state.app_name}: #{reason}",
            app: state.app_name,
            reason: reason
          )

          {:error, {:persist_failed, reason}}
      end

    {:reply, result, state}
  end

  # Test-only backdoor: mark this app's cached token as expired in ETS and
  # storage. Preserves parity with the legacy `Tokens.Server`'s :expire_token
  # path used by `test/ex_atlas/fly/tokens/server_test.exs`.
  @doc false
  def handle_call(:expire_token, _from, state) do
    expired_at = System.system_time(:second) - 1

    case :ets.lookup(state.table_name, state.app_name) do
      [{_, token, _}] ->
        :ets.insert(state.table_name, {state.app_name, token, expired_at})

      _ ->
        :ok
    end

    state.storage_mod.put(state.app_name, :cached, %{token: "expired", expires_at: expired_at})

    {:reply, :ok, state}
  end

  @impl GenServer
  # E7: proactive soft-expiry refresh. Scheduled from maybe_schedule_soft_expiry/3
  # after any resolve that wrote a `:cached` entry. When fired, we clear the
  # soft_expiry_ref slot and run the resolve chain in the background — same
  # logic as `:acquire_token`, but no reply tuple since nobody called us.
  def handle_info(:soft_expiry_refresh, state) do
    Logger.debug("[ExAtlas.Fly.Tokens] soft-expiry refresh firing",
      app: state.app_name
    )

    :ets.delete(state.table_name, state.app_name)
    now = System.system_time(:second)
    reply = resolve_token(now, state)

    {:noreply, maybe_schedule_soft_expiry(%{state | soft_expiry_ref: nil}, reply, now)}
  end

  # ── Private ──

  defp ets_lookup(table_name, app_name, now) do
    case :ets.lookup(table_name, app_name) do
      [{^app_name, token, expires_at}] when expires_at > now ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp resolve_token(now, state) do
    with :miss <- check_storage(now, state),
         :miss <- check_fly_config(state),
         :miss <- acquire_from_cli(state),
         :miss <- check_manual_token(state) do
      {{:error, :no_token_available}, :none}
    end
  end

  defp check_storage(now, state) do
    case state.storage_mod.get(state.app_name, :cached) do
      {:ok, %{token: token, expires_at: expires_at}}
      when is_integer(expires_at) and expires_at > now ->
        cache_token(state.table_name, state.app_name, token, expires_at)
        {{:ok, token}, :storage}

      _ ->
        :miss
    end
  end

  defp check_fly_config(%{config_file_enabled: false}), do: :miss

  defp check_fly_config(state) do
    case state.config_file_fn.() do
      {:ok, token} when is_binary(token) and token != "" ->
        expires_at = System.system_time(:second) + state.ttl_seconds
        cache_token(state.table_name, state.app_name, token, expires_at)
        persist_async(state, token, expires_at)
        {{:ok, token}, :config}

      _ ->
        :miss
    end
  end

  defp default_config_file_fn do
    path = Path.expand("~/.fly/config.yml")

    case File.read(path) do
      {:ok, content} ->
        case Regex.run(~r/^access_token:\s*(.+)$/m, content) do
          [_, token] ->
            token = token |> String.trim() |> String.trim("\"")
            if token != "", do: {:ok, token}, else: :miss

          nil ->
            :miss
        end

      {:error, _} ->
        :miss
    end
  end

  defp acquire_from_cli(state) do
    task =
      Task.async(fn ->
        state.cmd_fn.("fly", ["tokens", "create", "readonly"], stderr_to_stdout: true)
      end)

    case Task.yield(task, state.cli_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {token_output, 0}} ->
        token = String.trim(token_output)

        if token != "" do
          expires_at = System.system_time(:second) + state.ttl_seconds
          cache_token(state.table_name, state.app_name, token, expires_at)
          persist_async(state, token, expires_at)
          {{:ok, token}, :cli}
        else
          Logger.warning("[ExAtlas.Fly.Tokens] `fly tokens create` returned empty output",
            app: state.app_name
          )

          :miss
        end

      {:ok, {error_output, exit_code}} ->
        Logger.warning("[ExAtlas.Fly.Tokens] `fly tokens create` failed",
          app: state.app_name,
          exit_code: exit_code,
          output: String.trim(error_output)
        )

        :miss

      nil ->
        Logger.warning("[ExAtlas.Fly.Tokens] `fly tokens create` timed out",
          app: state.app_name,
          timeout_ms: state.cli_timeout_ms
        )

        :miss
    end
  end

  defp check_manual_token(state) do
    case state.storage_mod.get(state.app_name, :manual) do
      {:ok, %{token: token}} when is_binary(token) and token != "" ->
        {{:ok, token}, :manual}

      _ ->
        :miss
    end
  end

  defp cache_token(table_name, app_name, token, expires_at) do
    :ets.insert(table_name, {app_name, token, expires_at})
  end

  # Offload the cached-token persist write to a supervised Task so the
  # AppServer mailbox is not blocked on :dets.sync (can take tens of ms per
  # write). The caller already has a working token in ETS; durable storage
  # is a best-effort survival aid for VM restart.
  #
  # On failure, log at :error level — same contract as the synchronous
  # predecessor, just emitted from the task rather than the mailbox. A VM
  # crash in the gap between ETS write and storage sync loses only the
  # cached entry; manual tokens never go through this path (see set_manual
  # handle_call, which stays synchronous because manual tokens are not
  # re-acquirable and the caller must know if persist failed).
  #
  # When `state.task_sup` is nil (tests without a task supervisor in scope),
  # fall back to synchronous persist so the old behavior is preserved.
  defp persist_async(%{task_sup: nil} = state, token, expires_at) do
    persist_sync(state.storage_mod, state.app_name, token, expires_at)
  end

  defp persist_async(state, token, expires_at) do
    app_name = state.app_name
    storage_mod = state.storage_mod

    Task.Supervisor.start_child(state.task_sup, fn ->
      persist_sync(storage_mod, app_name, token, expires_at)
    end)

    :ok
  end

  defp persist_sync(storage_mod, app_name, token, expires_at) do
    storage_mod.put(app_name, :cached, %{token: token, expires_at: expires_at})
    :ok
  rescue
    e ->
      reason = Exception.message(e)

      Logger.error(
        "[ExAtlas.Fly.Tokens] cached token persist failed for #{app_name}: #{reason}",
        app: app_name,
        reason: reason
      )

      {:error, {:persist_failed, reason}}
  end

  # Read by the client-side timeout budget in `acquire/1` and `refresh/1`.
  # The server-side `state.cli_timeout_ms` is resolved once at init/1.
  defp cli_timeout_ms do
    Application.get_env(:ex_atlas, :fly, [])[:cli_timeout_ms] || @default_cli_timeout_ms
  end

  # E7: after any successful resolve, look up the fresh ETS entry's
  # expires_at and schedule a timer to fire `soft_expiry_lead_seconds`
  # before it. Cancel and replace any previous timer so each resolve
  # re-anchors the schedule. Skipped for `:manual` source (expires_at nil)
  # and for error replies.
  defp maybe_schedule_soft_expiry(state, reply, now) do
    state = cancel_soft_expiry(state)

    with %{soft_expiry_lead_seconds: lead} when is_integer(lead) and lead > 0 <- state,
         {{:ok, _token}, source} when source in [:storage, :config, :cli] <- reply,
         [{_, _, expires_at}] <- :ets.lookup(state.table_name, state.app_name),
         true <- is_integer(expires_at) do
      delay_seconds = expires_at - now - lead

      if delay_seconds > 0 do
        ref = Process.send_after(self(), :soft_expiry_refresh, delay_seconds * 1_000)
        %{state | soft_expiry_ref: ref}
      else
        state
      end
    else
      _ -> state
    end
  end

  defp cancel_soft_expiry(%{soft_expiry_ref: nil} = state), do: state

  defp cancel_soft_expiry(%{soft_expiry_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | soft_expiry_ref: nil}
  end
end
