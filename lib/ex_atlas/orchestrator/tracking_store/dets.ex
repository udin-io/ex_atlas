defmodule ExAtlas.Orchestrator.TrackingStore.Dets do
  @moduledoc """
  DETS-backed implementation of `ExAtlas.Orchestrator.TrackingStore`.

  The zero-config default: a single `:ex_atlas_tracked` table of
  `{id, record}`, written through a `GenServer` so writes are serialized, read
  directly via `:dets.lookup/2`. Same shape as
  `ExAtlas.Fly.TokenStorage.Dets`, and the same storage-path ladder.

  ## Storage path resolution

  1. `opts[:storage_path]` at startup.
  2. `config :ex_atlas, :orchestrator, storage_path: "..."`.
  3. `Application.app_dir(:ex_atlas, "priv/ex_atlas_orchestrator")` — dev/test.
  4. `Path.join(System.tmp_dir!(), "ex_atlas_orchestrator")` — used when the
     resolved directory is not writable, as a release's `priv` commonly is not.

  The directory is `chmod 0700` and the file `0600`: the records hold spawn
  opts, and even scrubbed those describe your infrastructure.

  ## The ephemeral-filesystem trap

  Steps 3 and 4 are both *inside the machine's own filesystem*. On Fly, a
  machine with **no attached volume** gets a fresh one on every deploy — so the
  store comes up empty, adoption does nothing, and the Reaper kills the pods
  this feature exists to save. Point `:storage_path` at a mounted volume, or
  implement `ExAtlas.Orchestrator.TrackingStore` against something already
  durable. This is why the behaviour, not this module, is the feature.

  ## A corrupt file is recoverable; the data in it is not

  `ExAtlas.Fly.TokenStorage.Dets` sets both precedents — recreate the
  re-acquirable table, refuse to start for the irreplaceable one. Tracking
  records are irreplaceable *and* this module lives in a host's supervision
  tree, so refusing to start would take their app down over a file we wrote.

  So a file that will not open (`repair: true` already tried) is deleted and
  recreated, loudly, and the store is marked **degraded for the rest of the
  boot**: `all/0` answers `{:error, _}` forever after, which
  `ExAtlas.Orchestrator.Adopter` turns into "adopt nothing, and never let the
  Reaper DELETE anything this boot". Writes made after the recreate work
  normally, so resources spawned by this boot are still tracked.

  `{:ok, []}` is reserved for "the store is fine and holds nothing". Conflating
  the two is what would get a live GPU job deleted.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  use GenServer

  require Logger

  @table :ex_atlas_tracked
  @filename "tracked.dets"

  @impl ExAtlas.Orchestrator.TrackingStore
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def get(id) do
    case :dets.lookup(@table, id) do
      [{^id, record}] -> {:ok, record}
      _absent_or_unreadable -> :error
    end
  rescue
    # The table is not open — the store is not running, or came up with no
    # table at all. A miss, not a crash: the caller is either the Reaper (which
    # is disabled this boot anyway) or a tracker tidying up after itself.
    ArgumentError -> :error
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def put(record), do: call({:put, record})

  @impl ExAtlas.Orchestrator.TrackingStore
  def delete(id), do: call({:delete, id})

  @impl ExAtlas.Orchestrator.TrackingStore
  def all do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, :all)
    end
  end

  defp call(message) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, message)
    end
  end

  @impl GenServer
  def init(opts) do
    dir = resolve_storage_dir(opts)
    _ = File.chmod(dir, 0o700)

    path = Path.join(dir, @filename)

    case open(path) do
      {:ok, table} ->
        _ = File.chmod(path, 0o600)
        {:ok, %{dir: dir, path: path, table: table, degraded: nil}}

      {:recreated, table, reason} ->
        _ = File.chmod(path, 0o600)
        {:ok, %{dir: dir, path: path, table: table, degraded: {:store_recreated, reason}}}

      {:error, reason} ->
        # Nothing left to try — come up with no table rather than take the
        # host's supervision tree down with us. Persistence is a no-op for this
        # boot and `all/0` says so, which disables reaping.
        Logger.error(
          "[ExAtlas.Orchestrator.TrackingStore.Dets] could not open #{path} " <>
            "(#{inspect(reason)}); persistence is disabled for this boot and " <>
            "the Reaper will not terminate anything"
        )

        {:ok, %{dir: dir, path: path, table: nil, degraded: {:store_unopenable, reason}}}
    end
  end

  @impl GenServer
  def handle_call({:put, _record}, _from, %{table: nil} = state), do: {:reply, :ok, state}

  def handle_call({:put, record}, _from, state) do
    :dets.insert(state.table, {record.id, record})
    :dets.sync(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:delete, _id}, _from, %{table: nil} = state), do: {:reply, :ok, state}

  def handle_call({:delete, id}, _from, state) do
    :dets.delete(state.table, id)
    :dets.sync(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:all, _from, %{degraded: reason} = state) when not is_nil(reason),
    do: {:reply, {:error, reason}, state}

  def handle_call(:all, _from, state) do
    records = :dets.foldl(fn {_id, record}, acc -> [record | acc] end, [], state.table)
    {:reply, {:ok, records}, state}
  end

  @impl GenServer
  def terminate(_reason, %{table: nil}), do: :ok

  def terminate(_reason, state) do
    _ = :dets.close(state.table)
    :ok
  end

  defp open(path) do
    charlist = String.to_charlist(path)

    case :dets.open_file(@table, file: charlist, type: :set, repair: true) do
      {:ok, @table} ->
        {:ok, @table}

      {:error, reason} ->
        Logger.warning(
          "[ExAtlas.Orchestrator.TrackingStore.Dets] tracking DETS file #{path} unreadable " <>
            "(#{inspect(reason)}); recreating. Adoption is skipped and the Reaper is " <>
            "DISABLED for this boot — this node can no longer tell which running compute " <>
            "is its own. Check for orphaned pods at your provider."
        )

        _ = File.rm(path)

        case :dets.open_file(@table, file: charlist, type: :set) do
          {:ok, @table} -> {:recreated, @table, reason}
          {:error, reason2} -> {:error, reason2}
        end
    end
  end

  # Mirrors `ExAtlas.Fly.TokenStorage.Dets`: try whichever path was resolved,
  # and fall back to tmp_dir for any of them — an explicitly configured but
  # read-only path must degrade, not crash the host's tree.
  defp resolve_storage_dir(opts) do
    primary =
      cond do
        path = Keyword.get(opts, :storage_path) -> path
        path = Application.get_env(:ex_atlas, :orchestrator, [])[:storage_path] -> path
        true -> Application.app_dir(:ex_atlas, "priv/ex_atlas_orchestrator")
      end

    ensure_writable(primary) || tmp_fallback(primary)
  end

  defp ensure_writable(dir) do
    case File.mkdir_p(dir) do
      :ok -> dir
      {:error, _} -> nil
    end
  end

  defp tmp_fallback(attempted) do
    fallback = Path.join(System.tmp_dir!(), "ex_atlas_orchestrator")

    Logger.warning(
      "[ExAtlas.Orchestrator.TrackingStore.Dets] storage path #{attempted} not writable; " <>
        "falling back to #{fallback}, which a release or a container almost certainly " <>
        "does not preserve across a deploy"
    )

    File.mkdir_p!(fallback)
    fallback
  end
end
