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
    * `:table_name` — override the ETS table to write into.
    * `:cmd_fn` — replaces `System.cmd/3`.
    * `:config_file_fn` — replaces the `~/.fly/config.yml` reader.
    * `:storage_mod` — replaces the storage module.
    * `:ttl_seconds` — token TTL (default 24h).
    * `:cli_timeout_ms` — `fly tokens create` timeout (default 15s).
  """

  use GenServer

  require Logger

  @default_table :ex_atlas_fly_tokens
  @default_ttl_seconds 24 * 60 * 60
  @default_cli_timeout_ms 15_000

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
    table_name = Keyword.get(opts, :table_name, @default_table)
    cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/3)
    config_file_fn = Keyword.get(opts, :config_file_fn, &default_config_file_fn/0)
    storage_mod = Keyword.get(opts, :storage_mod, resolve_storage_mod())
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    cli_timeout = Keyword.get(opts, :cli_timeout_ms, cli_timeout_ms())

    {:ok,
     %{
       app_name: app_name,
       table_name: table_name,
       cmd_fn: cmd_fn,
       config_file_fn: config_file_fn,
       storage_mod: storage_mod,
       ttl_seconds: ttl,
       cli_timeout_ms: cli_timeout
     }}
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

    {:reply, reply, state}
  end

  def handle_call(:invalidate, _from, state) do
    :ets.delete(state.table_name, state.app_name)
    {:reply, :ok, state}
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

  defp check_fly_config(state) do
    if config_file_enabled?() do
      case state.config_file_fn.() do
        {:ok, token} when is_binary(token) and token != "" ->
          expires_at = System.system_time(:second) + state.ttl_seconds
          cache_token(state.table_name, state.app_name, token, expires_at)
          persist(state.storage_mod, state.app_name, token, expires_at)
          {{:ok, token}, :config}

        _ ->
          :miss
      end
    else
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
          persist(state.storage_mod, state.app_name, token, expires_at)
          {{:ok, token}, :cli}
        else
          Logger.warning(
            "[ExAtlas.Fly.Tokens] `fly tokens create` returned empty output for #{state.app_name}"
          )

          :miss
        end

      {:ok, {error_output, _code}} ->
        Logger.warning(
          "[ExAtlas.Fly.Tokens] `fly tokens create` failed for #{state.app_name}: " <>
            String.trim(error_output)
        )

        :miss

      nil ->
        Logger.warning("[ExAtlas.Fly.Tokens] `fly tokens create` timed out for #{state.app_name}")

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

  # A persist failure means VM restart will lose the cached token. The caller
  # still gets a working token (ETS is authoritative for the current session),
  # but the event must be loud enough for operators to notice — :error level
  # with structured metadata.
  defp persist(storage_mod, app_name, token, expires_at) do
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

  defp resolve_storage_mod do
    Application.get_env(:ex_atlas, :fly, [])[:token_storage] || ExAtlas.Fly.TokenStorage.Dets
  end

  defp config_file_enabled? do
    case Application.get_env(:ex_atlas, :fly, [])[:fly_config_file_enabled] do
      nil -> true
      value -> value
    end
  end

  defp cli_timeout_ms do
    Application.get_env(:ex_atlas, :fly, [])[:cli_timeout_ms] || @default_cli_timeout_ms
  end
end
