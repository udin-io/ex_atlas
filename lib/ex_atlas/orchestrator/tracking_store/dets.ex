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
  recreated, loudly, and the store is marked **degraded for the life of the
  VM, across restarts of the store process**: `all/0` answers `{:error, _}`
  until the VM restarts, which `ExAtlas.Orchestrator.Adopter` turns into
  "adopt nothing, and never let the Reaper DELETE anything until the VM
  restarts": its retries read the same `{:error, _}`. A file
  that will not open even after the delete marks the store the same way.
  Writes made after the recreate work normally, so resources spawned by this
  boot are still tracked.

  A file this VM opened that is gone at the next start of the store, and a
  file that reads as garbage under the open table, count as lost records too.

  The mark lives in the VM, not the file. The next boot reads the file as it
  stands, the lost records missing, and its Reaper deletes their pods.

  `get/1` raises rather than answer `:error`, which means "not stored", when
  its table is not open (the process is down or restarting, or the file
  would not open), and on a miss while the store is marked: the record may be
  among the lost. A Reaper whose adoption settled before the loss then keeps
  every pod it asks about.

  `{:ok, []}` is reserved for "the store is fine and holds nothing". Conflating
  the two is what would get a live GPU job deleted.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  use GenServer

  require Logger

  @table :ex_atlas_tracked
  # The loss of whichever file the one `@table` has open, for `get/1`, which
  # runs in the caller's process.
  @loss_key {__MODULE__, :open_table_loss}
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

  # `:error` means "not stored", and the Reaper deletes a pod on it, so a table
  # that cannot answer raises. So does a miss on a store that lost records: the
  # record may be among the lost. Every caller rescues the raise and keeps the
  # pod.
  @impl ExAtlas.Orchestrator.TrackingStore
  def get(id) do
    case lookup(id) do
      [{^id, record}] -> {:ok, record}
      {:error, reason} -> cannot_answer(id, reason_kind(reason))
      _absent -> miss(id, :persistent_term.get(@loss_key, nil))
    end
  end

  defp miss(_id, nil), do: :error
  defp miss(id, {kind, _reason}), do: cannot_answer(id, kind)

  defp lookup(id) do
    :dets.lookup(@table, id)
  rescue
    # The table is not open: the store is not running, is restarting, or came
    # up with no table at all.
    ArgumentError -> {:error, :not_open}
  end

  # The message names the kind of fault only: a DETS reason carries the file
  # path.
  defp cannot_answer(id, kind) do
    raise ArgumentError,
          "#{inspect(__MODULE__)} cannot read the record of #{inspect(id)} (#{inspect(kind)})"
  end

  defp reason_kind(reason) when is_atom(reason), do: reason

  defp reason_kind(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason_kind(elem(reason, 0))

  defp reason_kind(_reason), do: :unknown

  @impl ExAtlas.Orchestrator.TrackingStore
  def put(record) do
    if is_nil(Process.whereis(__MODULE__)) do
      # `persist: true` is a durability promise, and dropping the write in
      # silence is how it gets discovered a deploy later, by a reaped pod.
      Logger.error(
        "[ExAtlas.Orchestrator.TrackingStore.Dets] not running; dropping the tracking " <>
          "record for #{record.id}. It will not be adopted at the next boot, and the " <>
          "Reaper will treat it as an orphan."
      )
    end

    call({:put, record})
  end

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
    # So a supervisor's shutdown runs `terminate/2`, which closes the table
    # before this process exits. Without it DETS closes the table only after
    # the exit, and a `get/1` in that moment still reads the file.
    Process.flag(:trap_exit, true)

    dir = resolve_storage_dir(opts)
    _ = File.chmod(dir, 0o700)

    # Expanded, so every spelling of one file shares its mark.
    path = dir |> Path.join(@filename) |> Path.expand()

    {:ok, state} = open_state(dir, path)
    _ = put_new(@loss_key, state.degraded)
    {:ok, state}
  end

  defp open_state(dir, path) do
    existed? = File.exists?(path)

    case open(path) do
      {:ok, table} ->
        _ = File.chmod(path, 0o600)
        degraded = if existed?, do: earlier_loss(path), else: vanished(path)
        _ = put_new(opened_key(path), true)
        {:ok, %{dir: dir, path: path, table: table, degraded: degraded}}

      {:recreated, table, reason} ->
        _ = File.chmod(path, 0o600)
        degraded = mark_lost(path, {:store_recreated, reason})
        {:ok, %{dir: dir, path: path, table: table, degraded: degraded}}

      {:error, reason} ->
        # Nothing left to try — come up with no table rather than take the
        # host's supervision tree down with us. Persistence is a no-op until the
        # VM restarts and `all/0` says so, which keeps reaping off.
        Logger.error(
          "[ExAtlas.Orchestrator.TrackingStore.Dets] could not open #{path} " <>
            "(#{inspect(reason)}); persistence is disabled and the Reaper will not " <>
            "terminate anything until the VM restarts"
        )

        degraded = mark_lost(path, {:store_unopenable, reason})
        {:ok, %{dir: dir, path: path, table: nil, degraded: degraded}}
    end
  end

  # The mark outlives this process, so a restart of the store cannot turn
  # "records lost" into "these are all of them". It lives for the VM, keyed by
  # the file: the next boot reads the file as it stands.
  defp mark_lost(path, degraded) do
    _ = put_new(lost_key(path), degraded)
    degraded
  end

  # A put of the value already stored costs nothing; any other put or erase
  # scans every process.
  defp put_new(key, value) do
    if :persistent_term.get(key, nil) != value, do: :persistent_term.put(key, value)
    :ok
  end

  defp earlier_loss(path) do
    case :persistent_term.get(lost_key(path), nil) do
      nil ->
        nil

      {kind, _reason} = degraded ->
        Logger.warning(
          "[ExAtlas.Orchestrator.TrackingStore.Dets] #{path} lost records earlier in this VM " <>
            "(#{kind}); all/0 answers {:error, _}, so adoption and the Reaper stay off, " <>
            "until the VM restarts"
        )

        degraded
    end
  end

  # DETS creates a missing file, which reads as "nothing was stored". That is
  # true only the first time this VM opens the path; after that the file was
  # deleted under us.
  defp vanished(path) do
    if :persistent_term.get(opened_key(path), false) do
      Logger.error(
        "[ExAtlas.Orchestrator.TrackingStore.Dets] #{path} is gone since this VM opened it; " <>
          "its records are lost. all/0 answers {:error, _}, so adoption and the Reaper " <>
          "stay off, until the VM restarts"
      )

      mark_lost(path, {:store_vanished, :enoent})
    else
      earlier_loss(path)
    end
  end

  defp lost_key(path), do: {__MODULE__, :lost_records, path}
  defp opened_key(path), do: {__MODULE__, :opened, path}

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
    {:reply, fold(state.table), state}
  end

  # A file garbled under the open table folds to fewer records than DETS
  # counts in memory, often none, or to an error. Either is a store that
  # cannot account for its contents, never `{:ok, fewer}`.
  defp fold(table) do
    case :dets.foldl(fn {_id, record}, acc -> [record | acc] end, [], table) do
      {:error, reason} ->
        {:error, {:store_unreadable, reason}}

      records ->
        if length(records) == :dets.info(table, :size),
          do: {:ok, records},
          else: {:error, {:store_unreadable, :count_mismatch}}
    end
  end

  # A linked process other than the parent (the `:dets` server) exited
  # abnormally: stop, as an untrapped exit would have. Anything else is
  # ignored, as GenServer's default ignores it: each crash opens a restart.
  @impl GenServer
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}
  def handle_info(_unexpected, state), do: {:noreply, state}

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
            "DISABLED until the VM restarts — this node can no longer tell which running compute " <>
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
