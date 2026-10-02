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

  # A host's migration for each step, as the upgrade notice tells it to write.
  defmodule StepOne do
    @moduledoc false
    use Ecto.Migration
    def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 1)
    def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down(version: 1)
  end

  defmodule StepTwo do
    @moduledoc false
    use Ecto.Migration
    def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 2)
    def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down(version: 2)
  end

  defp tables do
    %{rows: rows} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'atlas_%' ORDER BY name"
      )

    List.flatten(rows)
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

    # `spawn/1` writes from the caller's process. A host that spawns inside its
    # own transaction and then rolls back must not lose the record of a pod
    # that is running.
    test "survives a rollback of the caller's transaction", %{tmp_dir: dir} do
      start!(dir)

      assert {:error, :host_rolled_back} =
               Repo.transaction(fn ->
                 :ok = Store.put(record("pod-a"))
                 Repo.rollback(:host_rolled_back)
               end)

      assert {:ok, %{id: "pod-a"}} = Store.get("pod-a")
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
    test "survives a rollback of the caller's transaction", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))

      assert {:error, :host_rolled_back} =
               Repo.transaction(fn ->
                 :ok = Store.delete("pod-a")
                 Repo.rollback(:host_rolled_back)
               end)

      assert :error = Store.get("pod-a")
    end

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

    test "raises ArgumentError naming the start order when the repo is not running" do
      Application.put_env(:ex_atlas, :orchestrator, repo: Repo)
      on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)

      error = assert_raise ArgumentError, fn -> Store.start_link([]) end
      assert error.message =~ "ExAtlas.Test.Repo is not running"
      assert error.message =~ "ExAtlas.Orchestrator.Supervisor"
    end

    test "raises ArgumentError when :repo is not a module" do
      Application.put_env(:ex_atlas, :orchestrator, repo: "MyApp.Repo")
      on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)

      assert_raise ArgumentError, ~r/repo:/, fn -> Store.start_link([]) end
    end
  end

  describe "renew_lease/2" do
    test "writes the owner's expiry, and a renewal moves it", %{tmp_dir: dir} do
      start!(dir)

      assert :ok = Store.renew_lease("m1", 1_000_000)
      assert lease_expiry("m1") == 1_000_000
      assert :ok = Store.renew_lease("m1", 2_000_000)
      assert lease_expiry("m1") == 2_000_000
    end

    test "answers {:error, _} when the lease table was never migrated", %{tmp_dir: dir} do
      start!(dir, migrate: false)
      Ecto.Migrator.run(Repo, [{1, StepOne}], :up, all: true, log: false)

      assert {:error, _reason} = Store.renew_lease("m1", 1_000_000)
    end
  end

  describe "claim_expired/3" do
    # The rewrite ExAtlas passes: the record, owned by the claimer.
    defp to(owner), do: fn record -> {:ok, Map.put(record, :owner, owner)} end

    defp owned!(id, owner), do: :ok = Store.put(record(id, %{owner: owner}))

    test "claims the records of an owner whose lease expired, column and record alike", %{
      tmp_dir: dir
    } do
      start!(dir)
      owned!("pod-a", "m1")
      owned!("pod-b", "m1")
      :ok = Store.renew_lease("m1", 1_000)

      assert {:ok, claimed} = Store.claim_expired("m2", 2_000, to("m2"))

      assert claimed |> Enum.map(& &1.id) |> Enum.sort() == ["pod-a", "pod-b"]
      assert {:ok, %{owner: "m2"}} = Store.get("pod-a")
      assert owner_column("pod-a") == "m2"
    end

    test "control: claims nothing while the owner's lease is live", %{tmp_dir: dir} do
      start!(dir)
      owned!("pod-a", "m1")
      :ok = Store.renew_lease("m1", 3_000)

      assert {:ok, []} = Store.claim_expired("m2", 2_000, to("m2"))
      assert {:ok, %{owner: "m1"}} = Store.get("pod-a")
    end

    test "claims nothing of an owner that never held a lease", %{tmp_dir: dir} do
      start!(dir)
      owned!("pod-a", "m1")
      owned!("pod-u", nil)

      assert {:ok, []} = Store.claim_expired("m2", 2_000, to("m2"))
      assert {:ok, %{owner: "m1"}} = Store.get("pod-a")
    end

    test "never claims the claimer's own records", %{tmp_dir: dir} do
      start!(dir)
      owned!("pod-a", "m2")
      :ok = Store.renew_lease("m2", 1_000)

      assert {:ok, []} = Store.claim_expired("m2", 2_000, to("m2"))
    end

    test "leaves a record the rewrite skips", %{tmp_dir: dir} do
      start!(dir)
      owned!("pod-a", "m1")
      :ok = Store.renew_lease("m1", 1_000)

      assert {:ok, []} = Store.claim_expired("m2", 2_000, fn _record -> :skip end)
      assert {:ok, %{owner: "m1"}} = Store.get("pod-a")
      assert owner_column("pod-a") == "m1"
    end

    test "writes nothing when the owner renews between the read and the update", %{
      tmp_dir: dir
    } do
      start!(dir)
      owned!("pod-a", "m1")
      :ok = Store.renew_lease("m1", 1_000)

      renews_first = fn record ->
        :ok = Store.renew_lease("m1", 9_000)
        {:ok, Map.put(record, :owner, "m2")}
      end

      assert {:ok, []} = Store.claim_expired("m2", 2_000, renews_first)
      assert {:ok, %{owner: "m1"}} = Store.get("pod-a")
    end

    # The claimer writes a blob built from the row it read. A row that moved
    # to another owner meanwhile, even one whose lease expired too, keeps the
    # newer copy.
    test "writes nothing when the row moved to another expired owner since the read", %{
      tmp_dir: dir
    } do
      start!(dir)
      owned!("pod-a", "m1")
      :ok = Store.renew_lease("m1", 1_000)
      :ok = Store.renew_lease("m9", 1_000)

      moved_first = fn record ->
        :ok = Store.put(Map.merge(record, %{owner: "m9", user_id: "moved"}))
        {:ok, Map.put(record, :owner, "m2")}
      end

      assert {:ok, []} = Store.claim_expired("m2", 2_000, moved_first)
      assert {:ok, %{owner: "m9", user_id: "moved"}} = Store.get("pod-a")
    end

    # A database writer moves a live node's row to an owner it made up, whose
    # lease it set in the past. The record still names its signed owner.
    test "leaves a row whose owner column differs from the record's own :owner", %{
      tmp_dir: dir
    } do
      start!(dir)
      owned!("pod-a", "m1")
      :ok = Store.renew_lease("m1", 9_000)
      Repo.query!("UPDATE atlas_tracking_records SET owner = 'ghost' WHERE id = 'pod-a'")
      :ok = Store.renew_lease("ghost", 1_000)

      assert {:ok, []} = Store.claim_expired("m2", 2_000, to("m2"))
      assert {:ok, %{owner: "m1"}} = Store.get("pod-a")
      assert owner_column("pod-a") == "ghost"
    end

    test "two nodes claiming at once leave each record with exactly one owner", %{
      tmp_dir: dir
    } do
      start!(dir)
      ids = for n <- 1..20, do: "pod-#{n}"
      Enum.each(ids, &owned!(&1, "m1"))
      :ok = Store.renew_lease("m1", 1_000)

      [m2, m3] =
        ["m2", "m3"]
        |> Enum.map(&Task.async(fn -> Store.claim_expired(&1, 2_000, to(&1)) end))
        |> Task.await_many(10_000)

      assert {:ok, by_m2} = m2
      assert {:ok, by_m3} = m3
      m2_ids = MapSet.new(by_m2, & &1.id)
      m3_ids = MapSet.new(by_m3, & &1.id)

      assert MapSet.disjoint?(m2_ids, m3_ids)
      assert MapSet.union(m2_ids, m3_ids) == MapSet.new(ids)

      for id <- ids do
        {:ok, %{owner: owner}} = Store.get(id)
        assert owner_column(id) == owner
        assert if(id in m2_ids, do: owner == "m2", else: owner == "m3")
      end
    end

    test "answers {:error, _} when the lease table was never migrated", %{tmp_dir: dir} do
      start!(dir, migrate: false)
      Ecto.Migrator.run(Repo, [{1, StepOne}], :up, all: true, log: false)

      assert {:error, _reason} = Store.claim_expired("m2", 2_000, to("m2"))
    end
  end

  defp lease_expiry(owner) do
    %{rows: [[expires_at]]} =
      Repo.query!("SELECT expires_at FROM atlas_owner_leases WHERE owner = ?1", [owner])

    {:ok, at, 0} = DateTime.from_iso8601(expires_at)
    DateTime.to_unix(at, :millisecond)
  end

  defp owner_column(id) do
    %{rows: [[owner]]} =
      Repo.query!("SELECT owner FROM atlas_tracking_records WHERE id = ?1", [id])

    owner
  end

  describe "Migration" do
    test "down/0 outside a migration raises, and the table keeps its rows", %{tmp_dir: dir} do
      start!(dir)
      :ok = Store.put(record("pod-a"))

      assert_raise RuntimeError, ~r/migration runner/, fn -> Store.Migration.down() end
      assert {:ok, [%{id: "pod-a"}]} = Store.all()
    end

    test "up/1 refuses a version this build does not have" do
      assert_raise ArgumentError, ~r/version/, fn -> Store.Migration.up(version: 3) end
    end

    test "step 1 creates the records table alone; step 2 adds the lease table", %{
      tmp_dir: dir
    } do
      start!(dir, migrate: false)

      Ecto.Migrator.run(Repo, [{1, StepOne}], :up, all: true, log: false)
      assert tables() == ["atlas_tracking_records"]

      Ecto.Migrator.run(Repo, [{1, StepOne}, {2, StepTwo}], :up, all: true, log: false)
      assert tables() == ["atlas_owner_leases", "atlas_tracking_records"]
    end

    test "down(version: 2) drops the lease table and keeps the records", %{tmp_dir: dir} do
      start!(dir, migrate: false)
      Ecto.Migrator.run(Repo, [{1, StepOne}, {2, StepTwo}], :up, all: true, log: false)
      :ok = Store.put(record("pod-a"))

      Ecto.Migrator.run(Repo, [{1, StepOne}, {2, StepTwo}], :down, step: 1, log: false)

      assert tables() == ["atlas_tracking_records"]
      assert {:ok, [%{id: "pod-a"}]} = Store.all()
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
