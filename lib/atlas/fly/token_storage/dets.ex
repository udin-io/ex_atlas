defmodule Atlas.Fly.TokenStorage.Dets do
  @moduledoc """
  DETS-backed implementation of `Atlas.Fly.TokenStorage`.

  Durable, zero-config storage. Survives VM restarts. Writes are serialized
  through a GenServer to avoid DETS concurrency pitfalls; reads go direct via
  `:dets.lookup/2`.

  ## Storage path resolution

  1. `opts[:storage_path]` at startup.
  2. `config :atlas, :fly, storage_path: "..."`.
  3. `Application.app_dir(:atlas, "priv/atlas_fly")` — works in dev/test.
  4. `Path.join(System.tmp_dir!(), "atlas_fly")` — used when the priv dir is
     read-only (Mix releases commonly are).

  ## Tables

    * `:atlas_fly_tokens_cached` — `{app_name, token, expires_at}`
    * `:atlas_fly_tokens_manual` — `{app_name, token, nil}`

  If a DETS file fails to open cleanly (e.g. the VM was killed mid-write),
  `open_file` is retried with `repair: true`. If that still fails, the file
  is deleted and re-created — token data is always re-acquirable, so losing
  the cache is strictly a perf regression, not a correctness one.
  """

  @behaviour Atlas.Fly.TokenStorage

  use GenServer

  require Logger

  @cached_table :atlas_fly_tokens_cached
  @manual_table :atlas_fly_tokens_manual

  @impl Atlas.Fly.TokenStorage
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Atlas.Fly.TokenStorage
  def get(app_name, :cached), do: lookup(@cached_table, app_name)
  def get(app_name, :manual), do: lookup(@manual_table, app_name)

  @impl Atlas.Fly.TokenStorage
  def put(app_name, key, record) do
    GenServer.call(__MODULE__, {:put, table_for(key), app_name, record})
  end

  @impl Atlas.Fly.TokenStorage
  def delete(app_name, key) do
    GenServer.call(__MODULE__, {:delete, table_for(key), app_name})
  end

  @impl GenServer
  def init(opts) do
    dir = resolve_storage_dir(opts)
    File.mkdir_p!(dir)

    cached_path = Path.join(dir, "cached.dets") |> String.to_charlist()
    manual_path = Path.join(dir, "manual.dets") |> String.to_charlist()

    {:ok, @cached_table} = open(@cached_table, cached_path)
    {:ok, @manual_table} = open(@manual_table, manual_path)

    {:ok, %{dir: dir}}
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
  def terminate(_reason, _state) do
    _ = :dets.close(@cached_table)
    _ = :dets.close(@manual_table)
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

  defp open(name, path) do
    case :dets.open_file(name, file: path, type: :set, repair: true) do
      {:ok, ^name} ->
        {:ok, name}

      {:error, reason} ->
        Logger.warning(
          "[Atlas.Fly.TokenStorage.Dets] DETS file #{inspect(path)} unreadable (#{inspect(reason)}); recreating"
        )

        _ = File.rm(to_string(path))
        :dets.open_file(name, file: path, type: :set)
    end
  end

  defp resolve_storage_dir(opts) do
    cond do
      path = Keyword.get(opts, :storage_path) ->
        path

      path = Application.get_env(:atlas, :fly, [])[:storage_path] ->
        path

      true ->
        default_dir()
    end
  end

  defp default_dir do
    priv = Application.app_dir(:atlas, "priv/atlas_fly")

    case File.mkdir_p(priv) do
      :ok ->
        priv

      {:error, _} ->
        Path.join(System.tmp_dir!(), "atlas_fly")
    end
  end
end
