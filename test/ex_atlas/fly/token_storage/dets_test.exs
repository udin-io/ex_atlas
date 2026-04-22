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
end
