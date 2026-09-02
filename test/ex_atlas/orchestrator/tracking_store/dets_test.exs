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

  describe "on-disk permissions" do
    @describetag :unix

    test "the storage dir is 0700 and the DETS file 0600", %{tmp_dir: dir} do
      start_store!(dir)
      :ok = Dets.put(record("compute-perms"))

      assert file_mode(dir) == 0o700
      assert file_mode(Path.join(dir, "tracked.dets")) == 0o600
    end
  end

  defp file_mode(path) do
    %File.Stat{mode: mode} = File.stat!(path)
    Bitwise.band(mode, 0o777)
  end
end
