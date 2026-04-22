defmodule ExAtlas.Fly.Tokens.Server do
  @moduledoc """
  Cache-first Fly.io API token resolver.

  Per-app tokens are resolved in this order:

    1. **ETS cache** — O(1) in-memory, keyed by `app_name`. 24h TTL.
    2. **`ExAtlas.Fly.TokenStorage`** — durable (DETS by default) so cached
       tokens survive restarts.
    3. **`~/.fly/config.yml`** — the file `flyctl` writes after
       `fly auth login`. Gated by `:fly_config_file_enabled` (default `true`).
    4. **`fly tokens create readonly`** — CLI invocation with a 15s timeout.
    5. **Manual override** — a token the host stored via
       `ExAtlas.Fly.Tokens.set_manual/2`.

  The GenServer serializes all mutations (acquire, refresh, persist). ETS
  enables lock-free reads from any caller. The storage layer is pluggable via
  `config :ex_atlas, :fly, token_storage: MyModule`.

  ## ETS schema

      {app_name, token, expires_at_unix_seconds}

  ## Runtime options (for test injection)

    * `:cmd_fn` — replaces `System.cmd/3`.
    * `:config_file_fn` — replaces the `~/.fly/config.yml` reader.
    * `:storage_mod` — replaces the storage module (normally resolved via
      application env at boot; set this to inject a different storage in tests).
    * `:table_name` — override the ETS table name.
  """

  use GenServer

  require Logger

  @default_table :ex_atlas_fly_tokens
  @default_ttl_seconds 24 * 60 * 60
  @default_cli_timeout_ms 15_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns a token for `app_name`, acquiring it from the resolution chain if needed.
  """
  @spec get_token(String.t(), atom()) :: {:ok, String.t()} | {:error, :no_token_available}
  def get_token(app_name, server \\ __MODULE__) do
    table_name = get_table_name(server)
    now = System.system_time(:second)

    case ets_lookup(table_name, app_name, now) do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        timeout = cli_timeout_ms() + 5_000
        GenServer.call(server, {:acquire_token, app_name}, timeout)
    end
  end

  @doc "Drop the ETS entry for `app_name` so the next `get_token/2` re-acquires."
  @spec invalidate_token(String.t(), atom()) :: :ok
  def invalidate_token(app_name, server \\ __MODULE__) do
    GenServer.call(server, {:invalidate, app_name})
  end

  @doc """
  Persist a manual-override token (no expiry).

  Returns `{:error, {:persist_failed, reason}}` if the storage backend raises —
  manual tokens are the one case in atlas where the caller gets a real error
  rather than a silent log, because a manual token is not re-acquirable.
  """
  @spec set_manual_token(String.t(), String.t(), atom()) ::
          :ok | {:error, {:persist_failed, String.t()}}
  def set_manual_token(app_name, token, server \\ __MODULE__) do
    GenServer.call(server, {:set_manual_token, app_name, token})
  end

  @doc false
  def get_table_name(server) do
    GenServer.call(server, :get_table_name)
  end

  # ── Server callbacks ──

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table)
    cmd_fn = Keyword.get(opts, :cmd_fn, &System.cmd/3)
    config_file_fn = Keyword.get(opts, :config_file_fn, &default_config_file_fn/0)
    storage_mod = Keyword.get(opts, :storage_mod, resolve_storage_mod())
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)
    cli_timeout = Keyword.get(opts, :cli_timeout_ms, cli_timeout_ms())

    # If a previous owner crashed without running terminate/2, the named
    # table may still exist. Reclaim it rather than crashing on :ets.new.
    table =
      case :ets.whereis(table_name) do
        :undefined -> :ets.new(table_name, [:set, :protected, :named_table])
        existing -> existing
      end

    {:ok,
     %{
       table: table,
       table_name: table_name,
       cmd_fn: cmd_fn,
       config_file_fn: config_file_fn,
       storage_mod: storage_mod,
       ttl_seconds: ttl,
       cli_timeout_ms: cli_timeout
     }}
  end

  @impl GenServer
  def handle_call({:acquire_token, app_name}, _from, state) do
    now = System.system_time(:second)

    result =
      case ets_lookup(state.table_name, app_name, now) do
        {:ok, token} -> {:ok, token}
        :miss -> resolve_token(app_name, now, state)
      end

    {:reply, result, state}
  end

  def handle_call({:invalidate, app_name}, _from, state) do
    :ets.delete(state.table_name, app_name)
    {:reply, :ok, state}
  end

  def handle_call({:set_manual_token, app_name, token}, _from, state) do
    # Manual tokens are NOT re-acquirable — never silently swallow a
    # persist failure here.
    result =
      try do
        state.storage_mod.put(app_name, :manual, %{token: token, expires_at: nil})
        :ok
      rescue
        e ->
          reason = Exception.message(e)

          Logger.error(
            "[ExAtlas.Fly.Tokens] manual token persist failed for #{app_name}: #{reason}",
            app: app_name,
            reason: reason
          )

          {:error, {:persist_failed, reason}}
      end

    {:reply, result, state}
  end

  def handle_call({:expire_token, app_name}, _from, state) do
    expired_at = System.system_time(:second) - 1

    case :ets.lookup(state.table_name, app_name) do
      [{^app_name, token, _expires_at}] ->
        :ets.insert(state.table_name, {app_name, token, expired_at})

      _ ->
        :ok
    end

    state.storage_mod.put(app_name, :cached, %{token: "expired", expires_at: expired_at})

    {:reply, :ok, state}
  end

  def handle_call(:get_table_name, _from, state) do
    {:reply, state.table_name, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Clean up the named ETS table so a supervisor restart does not
    # ArgumentError on :ets.new in init/1 and burn the restart budget.
    if :ets.whereis(state.table_name) != :undefined do
      :ets.delete(state.table_name)
    end

    :ok
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

  defp resolve_token(app_name, now, state) do
    with :miss <- check_storage(app_name, now, state),
         :miss <- check_fly_config(app_name, state),
         :miss <- acquire_from_cli(app_name, state),
         :miss <- check_manual_token(app_name, state) do
      {:error, :no_token_available}
    end
  end

  defp check_storage(app_name, now, state) do
    case state.storage_mod.get(app_name, :cached) do
      {:ok, %{token: token, expires_at: expires_at}}
      when is_integer(expires_at) and expires_at > now ->
        cache_token(state.table_name, app_name, token, expires_at)
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp check_fly_config(app_name, state) do
    if config_file_enabled?() do
      case state.config_file_fn.() do
        {:ok, token} when is_binary(token) and token != "" ->
          expires_at = System.system_time(:second) + state.ttl_seconds
          cache_token(state.table_name, app_name, token, expires_at)
          persist(state.storage_mod, app_name, token, expires_at)
          {:ok, token}

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

  defp acquire_from_cli(app_name, state) do
    task =
      Task.async(fn ->
        state.cmd_fn.("fly", ["tokens", "create", "readonly"], stderr_to_stdout: true)
      end)

    case Task.yield(task, state.cli_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {token_output, 0}} ->
        token = String.trim(token_output)

        if token != "" do
          expires_at = System.system_time(:second) + state.ttl_seconds
          cache_token(state.table_name, app_name, token, expires_at)
          persist(state.storage_mod, app_name, token, expires_at)
          {:ok, token}
        else
          Logger.warning(
            "[ExAtlas.Fly.Tokens] `fly tokens create` returned empty output for #{app_name}"
          )

          :miss
        end

      {:ok, {error_output, _code}} ->
        Logger.warning(
          "[ExAtlas.Fly.Tokens] `fly tokens create` failed for #{app_name}: #{String.trim(error_output)}"
        )

        :miss

      nil ->
        Logger.warning("[ExAtlas.Fly.Tokens] `fly tokens create` timed out for #{app_name}")
        :miss
    end
  end

  defp check_manual_token(app_name, state) do
    case state.storage_mod.get(app_name, :manual) do
      {:ok, %{token: token}} when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        :miss
    end
  end

  defp cache_token(table_name, app_name, token, expires_at) do
    :ets.insert(table_name, {app_name, token, expires_at})
  end

  # Persist a cached token. A failure here means VM restart will lose the
  # cached token; the caller still gets a working token (ETS is authoritative
  # for the current session), but the event must be loud enough for operators
  # to notice — upgraded from :warning to :error and surfaced as a return tuple.
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
