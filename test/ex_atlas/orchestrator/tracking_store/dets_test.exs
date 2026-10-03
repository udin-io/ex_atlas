defmodule ExAtlas.Orchestrator.TrackingStore.DetsTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.TrackingStore.Dets

  @moduletag :tmp_dir

  defp record(id, overrides \\ %{}) do
    %{
      v: ExAtlas.Orchestrator.TrackingStore.version(),
      id: id,
      provider: :mock,
      opts: [gpu: :h100, image: "trainer:latest", mode: :task],
      spawned_at_ms: 1_700_000_000_000,
      max_runtime_ms: 90 * 60 * 1_000,
      respawns: 0,
      callback_task_id: "task-#{id}",
      report: nil,
      mode: :task,
      user_id: nil
    }
    |> Map.merge(overrides)
  end

  defp start_store!(dir) do
    start_supervised!({Dets, storage_path: dir})
  end

  describe "durability" do
    test "records survive the store process going away and coming back", %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-durable"))

      # The whole point of the store: the process that wrote it is not what
      # remembers it. Stop it the way a deploy does, then start a new one over
      # the same path.
      :ok = stop_supervised!(Dets)
      start_store!(dir)

      assert {:ok, [%{id: "compute-durable", spawned_at_ms: 1_700_000_000_000}]} = Dets.all()
    end

    test "a deleted record does not come back", %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-gone"))
      :ok = Dets.delete("compute-gone")

      :ok = stop_supervised!(Dets)
      start_store!(dir)

      assert {:ok, []} = Dets.all()
    end

    # A supervisor shutdown runs `terminate/2`, which closes the table before
    # the process exits. Left to the owner's death, DETS closes it a moment
    # later, longer for a bad file, and a store started in that moment finds
    # the table name taken and reads its own file as corrupt.
    test "a stopped store has closed its file, a bad one included", %{tmp_dir: dir} do
      file = Path.join(dir, "tracked.dets")

      # The window is a few ms at most, so one round can miss it.
      for _round <- 1..20 do
        start_store!(dir)
        :ok = Dets.put(record("compute-closing"))
        :ok = stop_supervised!(Dets)
        assert :dets.info(:ex_atlas_tracked) == :undefined

        start_store!(dir)
        File.write!(file, :binary.copy(<<0xFF>>, File.stat!(file).size))
        assert_raise ArgumentError, fn -> Dets.get("compute-closing") end
        :ok = stop_supervised!(Dets)
        assert :dets.info(:ex_atlas_tracked) == :undefined

        File.rm!(file)
      end
    end
  end

  # The store traps exits so its shutdown closes the table. It is linked to
  # OTP's `:dets` server too, and must still stop when that server dies,
  # rather than run on with a table nothing serves. On a peer node, so the
  # test VM keeps its own `:dets` server.
  # Each crash opens a restart window, so a message nobody expects is ignored,
  # as GenServer's default `handle_info/2` ignores it.
  test "keeps running past a stray message and a linked process's normal exit",
       %{tmp_dir: dir} do
    pid = start_store!(dir)
    :ok = Dets.put(record("compute-stray"))

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, :stray)
        send(pid, {:EXIT, self(), :normal})
        send(self(), {:alive?, survives?(pid)})
      end)

    assert_received {:alive?, true}
    assert Process.whereis(Dets) == pid
    assert {:ok, [%{id: "compute-stray"}]} = Dets.all()
    refute log =~ "terminating"
  end

  test "stops when the DETS server dies", %{tmp_dir: dir} do
    {_peer, node} = ExAtlas.Test.Cluster.start_peer!()
    {:ok, store} = :erpc.call(node, GenServer, :start, [Dets, [storage_path: dir], [name: Dets]])
    ref = Process.monitor(store)

    :erpc.call(node, Process, :exit, [:erpc.call(node, Process, :whereis, [:dets]), :kill])

    assert_receive {:DOWN, ^ref, :process, ^store, :killed}, 2_000
  end

  describe "a corrupt store" do
    test "comes up, but reports that it cannot account for its contents", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "tracked.dets"), :crypto.strong_rand_bytes(4_096))

      # Booting is not optional — this is a library inside someone else's
      # supervision tree, and refusing to start would take their app down.
      pid = start_store!(dir)
      assert is_pid(pid)

      # But `{:ok, []}` would be a lie that gets live pods killed: the caller
      # must be able to tell "nothing was stored" from "I lost the record of
      # what was stored".
      assert {:error, _reason} = Dets.all()
    end

    test "still accepts and serves writes made after the recreate", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "tracked.dets"), :crypto.strong_rand_bytes(4_096))
      start_store!(dir)

      :ok = Dets.put(record("compute-post-corruption"))

      assert {:ok, %{id: "compute-post-corruption"}} = Dets.get("compute-post-corruption")
    end
  end

  # Issue 154: the records a recreate lost stay lost when the store process
  # restarts, so `all/0` must not turn "lost" into "these are all of them".
  # The mark lasts for the life of the VM.
  describe "a store that lost records, after its process restarts" do
    defp corrupt!(dir),
      do: File.write!(Path.join(dir, "tracked.dets"), :crypto.strong_rand_bytes(4_096))

    defp restart_store!(dir) do
      :ok = stop_supervised!(Dets)
      start_store!(dir)
    end

    test "still answers {:error, _} from all/0, restart after restart, and logs why",
         %{tmp_dir: dir} do
      corrupt!(dir)
      ExUnit.CaptureLog.capture_log(fn -> start_store!(dir) end)
      :ok = Dets.put(record("compute-after-recreate"))
      assert {:error, {:store_recreated, _}} = Dets.all()

      log = ExUnit.CaptureLog.capture_log(fn -> restart_store!(dir) end)

      assert {:error, {:store_recreated, _}} = Dets.all()
      assert log =~ Path.join(dir, "tracked.dets")
      assert log =~ "until the VM restarts"

      ExUnit.CaptureLog.capture_log(fn -> restart_store!(dir) end)

      assert {:error, {:store_recreated, _}} = Dets.all()
      # The file itself opened intact: writes made after the recreate survive.
      assert {:ok, %{id: "compute-after-recreate"}} = Dets.get("compute-after-recreate")
    end

    test "a store killed and restarted by its supervisor still answers {:error, _}",
         %{tmp_dir: dir} do
      corrupt!(dir)
      old = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:pid, start_store!(dir)}) end)
      assert old =~ "recreating"
      assert_received {:pid, pid}

      ExUnit.CaptureLog.capture_log(fn ->
        Process.exit(pid, :kill)
        assert await_restart(pid)
      end)

      assert {:error, {:store_recreated, _}} = Dets.all()
    end

    test "raises on a miss, since the record may be among the lost, and answers a hit",
         %{tmp_dir: dir} do
      lost = Path.join(dir, "lost")
      intact = Path.join(dir, "intact")
      File.mkdir_p!(lost)
      File.mkdir_p!(intact)
      corrupt!(lost)
      ExUnit.CaptureLog.capture_log(fn -> start_store!(lost) end)
      :ok = Dets.put(record("compute-after-recreate"))

      assert {:ok, %{id: "compute-after-recreate"}} = Dets.get("compute-after-recreate")
      error = assert_raise ArgumentError, fn -> Dets.get("compute-lost") end
      assert error.message =~ "store_recreated"

      ExUnit.CaptureLog.capture_log(fn -> restart_store!(lost) end)
      assert_raise ArgumentError, fn -> Dets.get("compute-lost") end

      # Control: a store on an intact file answers a miss as "not stored".
      :ok = stop_supervised!(Dets)
      start_store!(intact)
      assert :error = Dets.get("compute-lost")
    end

    test "control: an intact store restarted logs no lost records", %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-intact"))

      log = ExUnit.CaptureLog.capture_log(fn -> restart_store!(dir) end)

      assert {:ok, [%{id: "compute-intact"}]} = Dets.all()
      refute log =~ "until the VM restarts"
    end

    test "marks only its own path: an intact store elsewhere in the same VM reads {:ok, _}",
         %{tmp_dir: dir} do
      lost = Path.join(dir, "lost")
      intact = Path.join(dir, "intact")
      File.mkdir_p!(lost)
      File.mkdir_p!(intact)

      start_store!(intact)
      :ok = Dets.put(record("compute-elsewhere"))
      :ok = stop_supervised!(Dets)

      corrupt!(lost)
      ExUnit.CaptureLog.capture_log(fn -> start_store!(lost) end)
      assert {:error, _} = Dets.all()
      :ok = stop_supervised!(Dets)

      start_store!(intact)
      assert {:ok, [%{id: "compute-elsewhere"}]} = Dets.all()
      :ok = stop_supervised!(Dets)

      # And the intact store did not clear the lost one's mark.
      ExUnit.CaptureLog.capture_log(fn -> start_store!(lost) end)
      assert {:error, {:store_recreated, _}} = Dets.all()
    end

    test "names the same path the same way: a relative storage path reads the mark too",
         %{tmp_dir: dir} do
      corrupt!(dir)
      ExUnit.CaptureLog.capture_log(fn -> start_store!(dir) end)

      relative = Path.relative_to_cwd(dir)
      assert relative != dir
      ExUnit.CaptureLog.capture_log(fn -> restart_store!(relative) end)

      assert {:error, {:store_recreated, _}} = Dets.all()
    end

    # A directory where the file should be: the open fails, the delete fails,
    # and the store comes up with no table. Any user reproduces it, root
    # included, unlike a read-only dir, which `init/1` chmods back to 0700.
    test "a file that would not open keeps its mark once it opens again", %{tmp_dir: dir} do
      path = Path.join(dir, "tracked.dets")
      File.mkdir_p!(path)

      ExUnit.CaptureLog.capture_log(fn -> start_store!(dir) end)
      assert {:error, {:store_unopenable, _}} = Dets.all()
      assert_raise ArgumentError, fn -> Dets.get("compute-any") end

      File.rm_rf!(path)
      ExUnit.CaptureLog.capture_log(fn -> restart_store!(dir) end)

      assert {:error, {:store_unopenable, _}} = Dets.all()
      # Control: the file did open this time.
      :ok = Dets.put(record("compute-reopened"))
      assert {:ok, %{id: "compute-reopened"}} = Dets.get("compute-reopened")
    end

    # The mark lives in the VM, not the file: the next boot reads the file as
    # it stands, the records the recreate lost missing. `docs/risks.md` names
    # this.
    test "a new VM starts clean and reads the records written after the recreate",
         %{tmp_dir: dir} do
      corrupt!(dir)
      ExUnit.CaptureLog.capture_log(fn -> start_store!(dir) end)
      :ok = Dets.put(record("compute-after-recreate"))
      assert {:error, _} = Dets.all()
      :ok = stop_supervised!(Dets)

      {_peer, node} = ExAtlas.Test.Cluster.start_peer!()
      {:ok, _pid} = :erpc.call(node, GenServer, :start, [Dets, [storage_path: dir], [name: Dets]])

      assert {:ok, [%{id: "compute-after-recreate"}]} = :erpc.call(node, Dets, :all, [])
    end
  end

  # `:error` means "not stored", and the Reaper deletes a pod on it. A table
  # that cannot answer must not say that (issue 154).
  describe "get/1 on a table that cannot answer" do
    test "raises when the store is not running; control: answers :error for an unknown id when it is",
         %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-closed"))
      assert :error = Dets.get("compute-never-stored")

      :ok = stop_supervised!(Dets)

      error = assert_raise ArgumentError, fn -> Dets.get("compute-closed") end
      assert error.message =~ "ExAtlas.Orchestrator.TrackingStore.Dets"
      assert error.message =~ ~s("compute-closed")
    end

    test "raises when the file under an open table reads as garbage, naming no path",
         %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-garbled"))
      assert {:ok, %{id: "compute-garbled"}} = Dets.get("compute-garbled")

      path = Path.join(dir, "tracked.dets")
      File.write!(path, :binary.copy(<<0xFF>>, File.stat!(path).size))

      error = assert_raise ArgumentError, fn -> Dets.get("compute-garbled") end
      assert error.message =~ ~s("compute-garbled")
      assert error.message =~ "bad_object"
      refute error.message =~ dir
    end
  end

  describe "on-disk permissions" do
    @describetag :unix

    test "the storage dir is 0700 and the DETS file 0600", %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-perms"))

      assert file_mode(dir) == 0o700
      assert file_mode(Path.join(dir, "tracked.dets")) == 0o600
    end
  end

  defp survives?(pid) do
    _ = :sys.get_state(pid)
    true
  catch
    :exit, _reason -> false
  end

  # Polls for up to 1 s until the supervisor has started a new store.
  defp await_restart(old, tries \\ 100) do
    case Process.whereis(Dets) do
      pid when is_pid(pid) and pid != old ->
        :sys.get_state(pid)
        true

      _gone_or_old when tries > 0 ->
        Process.sleep(10)
        await_restart(old, tries - 1)

      _gone_or_old ->
        false
    end
  end

  defp file_mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
