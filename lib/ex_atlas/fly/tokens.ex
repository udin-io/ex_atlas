defmodule ExAtlas.Fly.Tokens do
  @moduledoc """
  Public facade for Fly.io API token resolution.

  Per-app tokens are resolved in this order (first hit wins):

    1. **Shared ETS cache** (fast path, lock-free from the caller's process).
    2. Per-app `ExAtlas.Fly.Tokens.AppServer` — one process per app, started
       lazily on first miss. The AppServer runs the full resolution chain:
       durable storage → `~/.fly/config.yml` → `fly tokens create readonly`
       CLI → manual override.

  Concurrent callers for the **same** app coalesce at the AppServer's mailbox:
  the first caller does the CLI acquisition; subsequent callers wake up and
  re-check the ETS table (filled by the first caller) before descending the
  chain a second time. Concurrent callers for **different** apps run in
  parallel — each app has its own AppServer.

  The supervision tree (`ExAtlas.Fly.Tokens.Supervisor` +
  `ExAtlas.Fly.Tokens.ETSOwner` + `ExAtlas.Fly.Tokens.Registry` +
  a `DynamicSupervisor`) is started by `ExAtlas.Application` when the Fly
  sub-tree is enabled (default).

  ## Telemetry

  Emits `[:ex_atlas, :fly, :token, :acquire]` span events
  (`:start` / `:stop` / `:exception`). `:stop` metadata includes:

    * `app` — the Fly app name.
    * `source` — which link in the chain produced the token
      (`:ets` / `:storage` / `:config` / `:cli` / `:manual` / `:none`).
    * `acquirer` — either `:facade` (pure ETS fast-path hit; no AppServer
      mailbox round-trip) or `:app_server` (slow-path resolution or coalesced
      cache hit on the AppServer side). The ratio of `:facade` to
      `:app_server` is a direct measure of how effective the cross-process
      ETS fast path is.

  See `guides/telemetry.md` for the full reference.
  """

  alias ExAtlas.Fly.Tokens.{AppServer, Supervisor, ETSOwner}

  @acquire_event [:ex_atlas, :fly, :token, :acquire]

  @doc """
  Returns a token for `app_name`, acquiring it from the resolution chain if
  needed.
  """
  @spec get(String.t()) :: {:ok, String.t()} | {:error, :no_token_available}
  def get(app_name) do
    :telemetry.span(
      @acquire_event,
      %{app: app_name},
      fn ->
        {result, source, acquirer} = do_get(app_name)
        {result, %{app: app_name, source: source, acquirer: acquirer}}
      end
    )
  end

  defp do_get(app_name) do
    names = resolve_names()
    table = names.ets_table
    now = System.system_time(:second)

    case ets_lookup(table, app_name, now) do
      {:ok, token} ->
        # Pure fast-path hit — never touched the AppServer mailbox.
        {{:ok, token}, :ets, :facade}

      :miss ->
        slow_path(app_name, names)
    end
  end

  defp slow_path(app_name, names) do
    case Supervisor.resolve_app_server(app_name,
           registry: names.registry,
           dynamic_sup: names.dynamic_sup,
           ets_table: names.ets_table,
           app_server_defaults: names.app_server_defaults
         ) do
      {:ok, pid} ->
        # The AppServer returns {result, source}. Source of :ets here means
        # the mailbox re-check found the cache filled by a concurrent caller —
        # that's the coalescing signal, still emitted from :app_server.
        {result, source} = AppServer.acquire(pid)
        {result, source, :app_server}

      {:error, _} = err ->
        {err, :none, :app_server}
    end
  end

  @doc "Invalidate the ETS cache entry for `app_name`, forcing re-acquisition."
  @spec invalidate(String.t()) :: :ok
  def invalidate(app_name) do
    names = resolve_names()

    case Registry.lookup(names.registry, app_name) do
      [{pid, _}] ->
        AppServer.invalidate(pid)

      [] ->
        # No AppServer means this app was never resolved, so there is nothing
        # in the shared table for it either — nothing to do. Starting an
        # AppServer just to invalidate would be pointless work.
        :ok
    end
  end

  @doc """
  Store a manual override token for `app_name` (used as a last-resort
  fallback in the resolution chain).

  Returns `{:error, {:persist_failed, reason}}` if the underlying storage
  raises — manual tokens are not re-acquirable, so the failure is surfaced
  rather than logged.
  """
  @spec set_manual(String.t(), String.t()) ::
          :ok | {:error, {:persist_failed, String.t()}}
  def set_manual(app_name, token) do
    names = resolve_names()

    case Supervisor.resolve_app_server(app_name,
           registry: names.registry,
           dynamic_sup: names.dynamic_sup,
           ets_table: names.ets_table,
           app_server_defaults: names.app_server_defaults
         ) do
      {:ok, pid} ->
        AppServer.set_manual(pid, token)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Private ──

  defp ets_lookup(table, app_name, now) do
    case :ets.lookup(table, app_name) do
      [{^app_name, token, expires_at}] when expires_at > now ->
        {:ok, token}

      _ ->
        :miss
    end
  rescue
    # Table may not be loaded yet (pre-init reads), or may have been torn
    # down by an ETSOwner restart. Treat as cache miss; the AppServer
    # resolve path will rebuild it.
    ArgumentError -> :miss
  end

  # Resolves the runtime names the facade dispatches to. Production uses
  # fixed module-level constants from Supervisor. Tests override via
  # `Application.put_env(:ex_atlas, :fly_tokens_names, %{...})`.
  defp resolve_names do
    overrides = Application.get_env(:ex_atlas, :fly_tokens_names, %{})

    %{
      registry: Map.get(overrides, :registry, Supervisor.registry_name()),
      dynamic_sup: Map.get(overrides, :dynamic_sup, Supervisor.dynamic_supervisor_name()),
      ets_owner: Map.get(overrides, :ets_owner, ETSOwner),
      ets_table: Map.get(overrides, :ets_table, Supervisor.ets_table_name()),
      app_server_defaults: Map.get(overrides, :app_server_defaults, [])
    }
  end
end
