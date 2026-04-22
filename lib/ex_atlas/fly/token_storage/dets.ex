defmodule ExAtlas.Fly.TokenStorage.Dets do
  @moduledoc """
  DETS-backed implementation of `ExAtlas.Fly.TokenStorage`.

  Durable, zero-config storage. Survives VM restarts. Writes are serialized
  through a GenServer to avoid DETS concurrency pitfalls; reads go direct via
  `:dets.lookup/2`.

  ## Storage path resolution

  1. `opts[:storage_path]` at startup.
  2. `config :ex_atlas, :fly, storage_path: "..."`.
  3. `Application.app_dir(:ex_atlas, "priv/ex_atlas_fly")` — works in dev/test.
  4. `Path.join(System.tmp_dir!(), "atlas_fly")` — used when the priv dir is
     read-only (Mix releases commonly are).

  ## Tables

    * `:ex_atlas_fly_tokens_cached` — `{app_name, token, expires_at}`
    * `:ex_atlas_fly_tokens_manual` — `{app_name, token, nil}`

  If a DETS file fails to open cleanly (e.g. the VM was killed mid-write),
  `open_file` is retried with `repair: true`. If that still fails, the file
  is deleted and re-created — token data is always re-acquirable, so losing
  the cache is strictly a perf regression, not a correctness one.
  """

  @behaviour ExAtlas.Fly.TokenStorage

  use GenServer

  require Logger

  @cached_table :ex_atlas_fly_tokens_cached
  @manual_table :ex_atlas_fly_tokens_manual

  @impl ExAtlas.Fly.TokenStorage
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl ExAtlas.Fly.TokenStorage
  def get(app_name, :cached), do: lookup(@cached_table, app_name)
  def get(app_name, :manual), do: lookup(@manual_table, app_name)

  @impl ExAtlas.Fly.TokenStorage
  def put(app_name, key, record) do
    GenServer.call(__MODULE__, {:put, table_for(key), app_name, record})
  end

  @impl ExAtlas.Fly.TokenStorage
  def delete(app_name, key) do
    GenServer.call(__MODULE__, {:delete, table_for(key), app_name})
  end

  @impl GenServer
  def init(opts) do
    dir = resolve_storage_dir(opts)
    File.mkdir_p!(dir)

    cached_table = Keyword.get(opts, :cached_table, @cached_table)
    manual_table = Keyword.get(opts, :manual_table, @manual_table)

    cached_path = Path.join(dir, "cached.dets") |> String.to_charlist()
    manual_path = Path.join(dir, "manual.dets") |> String.to_charlist()

    with {:ok, ^cached_table} <- open_cached(cached_table, cached_path),
         {:ok, ^manual_table} <- open_manual(manual_table, manual_path) do
      {:ok, %{dir: dir, cached_table: cached_table, manual_table: manual_table}}
    end
  end

  @impl GenServer
  def handle_call({:put, table, app_name, record}, _from, state) do
    :dets.insert(table, {app_name, record.token, record.expires_at})
    :dets.sync(table)
    {:reply, :ok, state}
  end

  def handle_call({:delete, table, app_name}, _from, state) do
    :dets.delete(table, app_name)
    :dets.sync(table)
    {:reply, :ok, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    _ = :dets.close(state.cached_table)
    _ = :dets.close(state.manual_table)
    :ok
  end

  defp table_for(:cached), do: @cached_table
  defp table_for(:manual), do: @manual_table

  defp lookup(table, app_name) do
    case :dets.lookup(table, app_name) do
      [{^app_name, token, expires_at}] ->
        {:ok, %{token: token, expires_at: expires_at}}

      _ ->
        :error
    end
  rescue
    # Table may not be loaded yet (pre-init reads) — return miss rather than crash.
    ArgumentError -> :error
  end

  # Cached tokens are re-acquirable. A corrupt cached file is a perf regression
  # only, so fall back to recreating the file if repair fails — the server
  # must still come up because manual-token lookups depend on it.
  defp open_cached(name, path) do
    case :dets.open_file(name, file: path, type: :set, repair: true) do
      {:ok, ^name} ->
        {:ok, name}

      {:error, reason} ->
        Logger.warning(
          "[ExAtlas.Fly.TokenStorage.Dets] cached token DETS file #{inspect(path)} unreadable (#{inspect(reason)}); recreating"
        )

        _ = File.rm(to_string(path))

        case :dets.open_file(name, file: path, type: :set) do
          {:ok, ^name} -> {:ok, name}
          {:error, reason2} -> {:stop, {:cached_dets_unopenable, path, reason2}}
        end
    end
  end

  # Manual tokens are NOT re-acquirable. If the manual DETS file is corrupt,
  # refuse to start and leave the file in place so an operator can decide —
  # silently recreating would wipe a bearer token that the user manually set.
  defp open_manual(name, path) do
    case :dets.open_file(name, file: path, type: :set, repair: true) do
      {:ok, ^name} ->
        {:ok, name}

      {:error, reason} ->
        Logger.error(
          "[ExAtlas.Fly.TokenStorage.Dets] manual token DETS file #{inspect(path)} " <>
            "unreadable (#{inspect(reason)}); refusing to auto-recreate — " <>
            "operator intervention required (the file contains bearer tokens that are " <>
            "NOT re-acquirable from the Fly API)"
        )

        {:stop, {:manual_dets_corrupt, path, reason}}
    end
  end

  defp resolve_storage_dir(opts) do
    cond do
      path = Keyword.get(opts, :storage_path) ->
        path

      path = Application.get_env(:ex_atlas, :fly, [])[:storage_path] ->
        path

      true ->
        default_dir()
    end
  end

  defp default_dir do
    priv = Application.app_dir(:ex_atlas, "priv/ex_atlas_fly")

    case File.mkdir_p(priv) do
      :ok ->
        priv

      {:error, _} ->
        Path.join(System.tmp_dir!(), "atlas_fly")
    end
  end
end
