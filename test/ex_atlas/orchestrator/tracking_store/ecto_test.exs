defmodule ExAtlas.Orchestrator.TrackingStore.EctoTest do
  @moduledoc """
  What the Ecto store does beyond the shared conformance suite: a table that
  is missing, rows that will not decode, the `owner` column, a repo that is
  unset or down, and the migration module run outside a migration.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store
  alias ExAtlas.Orchestrator.TrackingStoreConformance
  alias ExAtlas.Test.Repo

  @moduletag :tmp_dir

  defp record(id, overrides \\ %{}), do: TrackingStoreConformance.record(id, overrides)

  defp start!(dir, opts \\ []) do
    Repo.start!(dir, opts)
    start_supervised!(Store)
    :ok
  end

  # A row as any writer of the host's database could leave it.
  defp insert_raw!(id, blob, owner \\ nil) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO atlas_tracking_records (id, owner, record, inserted_at, updated_at) " <>
        "VALUES (?1, ?2, ?3, ?4, ?4)",
      [id, owner, {:blob, blob}, now]
    )
  end

  # `term_to_binary/1` of a record that holds an atom no module on this node
  # has ever named. Built by rewriting a string in the encoding, so the test
  # never creates the atom itself.
  defp blob_with_unknown_atom(id) do
    placeholder = "atlas-placeholder-string"
    name = "zz_atlas_unknown_" <> Base.encode16(:crypto.strong_rand_bytes(8))
    blob = :erlang.term_to_binary(record(id, %{user_id: placeholder}))

    :binary.replace(
      blob,
      <<109, byte_size(placeholder)::32, placeholder::binary>>,
      <<119, byte_size(name)::8, name::binary>>
    )
  end

  describe "all/0" do
    test "answers {:error, _} when the table was never migrated", %{tmp_dir: dir} do
      start!(dir, migrate: false)

      assert {:error, _reason} = Store.all()
    end

    test "answers {:ok, records} for rows that decode (control)", %{tmp_dir: dir} do
      start!(dir)
      insert_raw!("pod-a", :erlang.term_to_binary(record("pod-a")))
      insert_raw!("pod-b", :erlang.term_to_binary(record("pod-b")))

      assert {:ok, records} = Store.all()
      assert Enum.sort(Enum.map(records, & &1.id)) == ["pod-a", "pod-b"]
    end

    test "refuses every row when one names an atom this node lacks", %{tmp_dir: dir} do
      start!(dir)
      insert_raw!("pod-a", :erlang.term_to_binary(record("pod-a")))
      insert_raw!("pod-atom", blob_with_unknown_atom("pod-atom"))

      assert {:error, {:undecodable, ["pod-atom"]}} = Store.all()
    end

    test "refuses every row when one holds a function", %{tmp_dir: dir} do
      start!(dir)
      insert_raw!("pod-a", :erlang.term_to_binary(record("pod-a")))
      blob = :erlang.term_to_binary(record("pod-fun", %{report: fn -> :ran end}))
      insert_raw!("pod-fun", blob)

      assert {:error, {:undecodable, ["pod-fun"]}} = Store.all()
    end

    test "refuses a row that is not a term, or holds another id's record", %{tmp_dir: dir} do
      start!(dir)
      insert_raw!("pod-junk", "not an external term")
      insert_raw!("pod-moved", :erlang.term_to_binary(record("pod-other")))
      insert_raw!("pod-list", :erlang.term_to_binary([:not, :a, :record]))

      assert {:error, {:undecodable, ids}} = Store.all()
      assert Enum.sort(ids) == ["pod-junk", "pod-list", "pod-moved"]
    end

    # A compressed term declares its own decoded size, up to 4 GB, so a row of
    # a few hundred KB could take the node's memory at boot.
    test "refuses a compressed row", %{tmp_dir: dir} do
      start!(dir)
      blob = :erlang.term_to_binary(record("pod-z"), [:compressed])
      assert <<131, 80, _rest::binary>> = blob
      insert_raw!("pod-z", blob)

      assert {:error, {:undecodable, ["pod-z"]}} = Store.all()
    end

    test "refuses a row over 1 MiB, and reads one just under it", %{tmp_dir: dir} do
      start!(dir)

      big =
        :erlang.term_to_binary(record("pod-big", %{user_id: String.duplicate("a", 1_048_576)}))

      near = record("pod-near", %{user_id: String.duplicate("a", 1_047_000)})
      assert byte_size(:erlang.term_to_binary(near)) <= 1_048_576
      insert_raw!("pod-big", big)
      :ok = Store.put(near)

      assert {:error, {:undecodable, ["pod-big"]}} = Store.all()
      assert {:ok, ^near} = Store.get("pod-near")
    end

    test "answers {:error, _} when the repo is down", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))
      stop_supervised!(Repo)

      assert {:error, _reason} = Store.all()
    end
  end

  describe "get/1" do
    # The Reaper reads a raise as "ours, leave it" and `:error` as "not ours".
    # A row that exists but will not decode must not read as `:error`.
    test "raises on a row that will not decode, never answers :error", %{tmp_dir: dir} do
      start!(dir)
      insert_raw!("pod-atom", blob_with_unknown_atom("pod-atom"))

      assert_raise ArgumentError, ~r/pod-atom/, fn -> Store.get("pod-atom") end
    end

    test "raises when the repo is down", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))
      stop_supervised!(Repo)

      assert_raise RuntimeError, fn -> Store.get("pod-a") end
    end
  end

  describe "put/1" do
    test "on an existing id replaces the row and its owner column", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a", %{owner: "web-1", respawns: 0}))
      :ok = Store.put(record("pod-a", %{owner: "web-2", respawns: 2}))

      assert %{rows: [["pod-a", "web-2"]]} =
               Repo.query!("SELECT id, owner FROM atlas_tracking_records")

      assert {:ok, %{owner: "web-2", respawns: 2}} = Store.get("pod-a")
    end

    test "writes no owner for an unowned record", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a", %{owner: nil}))

      assert %{rows: [[nil]]} = Repo.query!("SELECT owner FROM atlas_tracking_records")
    end

    # 0.8.0 wrote records without `:respawning` (#115). The store keeps a
    # record as it was given, so the reader sees the field missing, not
    # invented, and a nil stays nil.
    test "keeps a record without :respawning as it was given, and nil as nil",
         %{tmp_dir: dir} do
      start!(dir)
      old = Map.delete(record("pod-old"), :respawning)
      :ok = Store.put(old)
      :ok = Store.put(record("pod-nil", %{respawning: nil}))

      assert {:ok, ^old} = Store.get("pod-old")
      assert {:ok, %{respawning: nil}} = Store.get("pod-nil")
    end

    # The store never writes a row it would refuse to read.
    test "logs and writes nothing for a record over 1 MiB", %{tmp_dir: dir} do
      start!(dir)
      big = record("pod-big", %{user_id: String.duplicate("a", 1_048_576)})

      log = capture_log(fn -> assert :ok = Store.put(big) end)
      assert log =~ "pod-big"
      assert log =~ "1048576 bytes"
      assert :error = Store.get("pod-big")
    end

    test "logs and returns :ok when the repo is down, so a tracker runs on",
         %{tmp_dir: dir} do
      start!(dir)
      stop_supervised!(Repo)

      log = capture_log(fn -> assert :ok = Store.put(record("pod-a")) end)
      assert log =~ "pod-a"
      assert log =~ "not be adopted"
    end
  end

  describe "delete/1" do
    test "logs and returns :ok when the repo is down", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))
      stop_supervised!(Repo)

      log = capture_log(fn -> assert :ok = Store.delete("pod-a") end)
      assert log =~ "pod-a"
    end
  end

  describe "start_link/1" do
    test "raises ArgumentError naming the key when :repo is unset" do
      Application.delete_env(:ex_atlas, :orchestrator)

      assert_raise ArgumentError, ~r/config :ex_atlas, :orchestrator, repo:/, fn ->
        Store.start_link([])
      end
    end

    test "raises ArgumentError when :repo is not a module" do
      Application.put_env(:ex_atlas, :orchestrator, repo: "MyApp.Repo")
      on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)

      assert_raise ArgumentError, ~r/repo:/, fn -> Store.start_link([]) end
    end
  end

  describe "Migration" do
    test "down/0 outside a migration raises, and the table keeps its rows", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))

      assert_raise RuntimeError, ~r/migration runner/, fn -> Store.Migration.down() end
      assert {:ok, [%{id: "pod-a"}]} = Store.all()
    end

    test "up/1 refuses a version this build does not have" do
      assert_raise ArgumentError, ~r/version/, fn -> Store.Migration.up(version: 2) end
    end

    test "down runs inside a migration and drops the table", %{tmp_dir: dir} do
      start!(dir)

      Ecto.Migrator.run(Repo, [{20_261_002_000_000, Repo.AddAtlasTracking}], :down,
        all: true,
        log: false
      )

      assert {:error, _no_table} = Store.all()
    end
  end
end
