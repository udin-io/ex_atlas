defmodule ExAtlas.Fly.TokenStorage.DetsTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Fly.TokenStorage.Dets

  @tmp_root "tmp/ex_atlas_fly_dets_test"

  setup do
    unique = System.unique_integer([:positive])
    storage_dir = Path.expand(Path.join(@tmp_root, "#{unique}"))
    File.rm_rf!(storage_dir)
    File.mkdir_p!(storage_dir)

    # Per-test GenServer name + table names so we don't collide with the
    # application's default Dets instance already running.
    process_name = :"dets_test_#{unique}"
    cached_table = :"dets_test_cached_#{unique}"
    manual_table = :"dets_test_manual_#{unique}"

    on_exit(fn -> File.rm_rf!(storage_dir) end)

    %{
      dir: storage_dir,
      unique: unique,
      process_name: process_name,
      cached_table: cached_table,
      manual_table: manual_table
    }
  end

  defp start_opts(context) do
    [
      name: context.process_name,
      storage_path: context.dir,
      cached_table: context.cached_table,
      manual_table: context.manual_table
    ]
  end

  describe "manual token DETS corruption (H10)" do
    test "init refuses to start and does NOT delete the manual file when corrupt", context do
      manual_path = Path.join(context.dir, "manual.dets")

      # Write garbage DETS cannot repair.
      File.write!(manual_path, :crypto.strong_rand_bytes(4_096))

      Process.flag(:trap_exit, true)
      result = Dets.start_link(start_opts(context))
      Process.flag(:trap_exit, false)

      assert match?({:error, {:manual_dets_corrupt, _, _}}, result),
             "expected {:error, {:manual_dets_corrupt, _, _}}, got #{inspect(result)}"

      # The manual file must still exist — operator intervention required,
      # not a silent wipe of a bearer token that is NOT re-acquirable.
      assert File.exists?(manual_path),
             "manual.dets was silently deleted; H10 regression"
    end

    test "cached token DETS corruption is recovered by recreating the file", context do
      cached_path = Path.join(context.dir, "cached.dets")
      File.write!(cached_path, :crypto.strong_rand_bytes(4_096))

      # Cached path SHOULD recover — losing the cache is a perf regression
      # only, and we want the server to come up so manual tokens stay reachable.
      assert {:ok, pid} = Dets.start_link(start_opts(context))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    end
  end

  describe "clean start" do
    test "opens both tables with empty storage dir", context do
      assert {:ok, pid} = Dets.start_link(start_opts(context))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert File.exists?(Path.join(context.dir, "cached.dets"))
      assert File.exists?(Path.join(context.dir, "manual.dets"))
    end
  end

  describe "mkdir fallback (M6)" do
    @describetag :unix

    test "explicitly-configured read-only path falls back to tmp_dir", context do
      # Create a read-only parent so the configured subdirectory cannot
      # be created. Post-M6 this falls back to a tmp_dir path; pre-M6
      # init/1 raised on File.mkdir_p! and took down the Fly tree.
      readonly_parent = Path.join(Path.expand(@tmp_root), "ro_#{context.unique}")
      File.mkdir_p!(readonly_parent)
      File.chmod!(readonly_parent, 0o500)

      on_exit(fn ->
        File.chmod!(readonly_parent, 0o700)
        File.rm_rf!(readonly_parent)
      end)

      bad_path = Path.join(readonly_parent, "not_writable")

      opts =
        context
        |> start_opts()
        |> Keyword.put(:storage_path, bad_path)

      assert {:ok, pid} = Dets.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Server must be up and functional despite the configured path failing.
      assert Process.alive?(pid)
    end
  end

  describe "file permissions (M7)" do
    @describetag :unix

    test "storage dir is 0700 after init", context do
      assert {:ok, pid} = Dets.start_link(start_opts(context))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      %File.Stat{mode: mode} = File.stat!(context.dir)
      # Low 9 bits are the rwx permission triad.
      assert Bitwise.band(mode, 0o777) == 0o700,
             "dir mode was #{Integer.to_string(Bitwise.band(mode, 0o777), 8)}, expected 700"
    end

    test "DETS files are 0600 after init", context do
      assert {:ok, pid} = Dets.start_link(start_opts(context))
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      for file <- ["cached.dets", "manual.dets"] do
        path = Path.join(context.dir, file)
        %File.Stat{mode: mode} = File.stat!(path)

        assert Bitwise.band(mode, 0o777) == 0o600,
               "#{file} mode was #{Integer.to_string(Bitwise.band(mode, 0o777), 8)}, expected 600"
      end
    end
  end
end
