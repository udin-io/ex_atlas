defmodule ExAtlas.Orchestrator.AdopterSealTest do
  @moduledoc """
  An adopted task respawns only from a record this node signed (issue 131).

  Whoever can write the tracking store writes the record a respawn after
  adoption rents from: its image, command, env names, callback descriptor and
  resolver tuple. The node signs every record it writes with a key from its
  callback secret, and refuses the respawn of a record whose signature does
  not check.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Events, TrackingStore}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.{CredentialResolver, Repo}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  @moduletag :tmp_dir

  defp start_dets!(dir) do
    TestOrchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})
    TrackingStore.Dets
  end

  defp start_ecto!(dir) do
    Repo.start!(dir)
    TestOrchestrator.start!(tracking_store: TrackingStore.Ecto)
    TrackingStore.Ecto
  end

  # What a writer of the host's database leaves, bypassing the app.
  defp put_row!(record) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT OR REPLACE INTO atlas_tracking_records " <>
        "(id, owner, record, inserted_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)",
      [record.id, record[:owner], {:blob, :erlang.term_to_binary(record)}, now]
    )
  end

  # A spot task that can respawn once, whose node then dies under it: the pod
  # runs on, and the record the node signed is all that is left.
  defp orphaned_task(overrides \\ []) do
    opts =
      Keyword.merge(
        [
          provider: :mock,
          gpu: :h100,
          image: "trainer-signed:latest",
          name: "atlas-sealed",
          mode: :task,
          max_runtime_ms: 90 * 60 * 1_000,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 30,
          persist: true,
          callback: "https://app.example.com/atlas/cb",
          respawn_credentials: {CredentialResolver, :resolve, [{:report, self(), :fixed_env}]},
          env: %{"HF_TOKEN" => "hf-orig-0c4d"}
        ],
        overrides
      )

    {:ok, pid, compute} = Orchestrator.spawn(opts)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    TestOrchestrator.sync_registry()
    compute
  end

  defp adopt_and_preempt(id) do
    Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
    :ok = Adopter.run(notify: self())
    assert_receive :adoption_complete, 2_000
    {:ok, pid} = Orchestrator.lookup(id)
    :ok = Mock.forget(id)
    pid
  end

  describe "a record the node signed (control)" do
    test "respawns after adoption, and the replacement's record is signed", %{tmp_dir: dir} do
      store = start_dets!(dir)
      %{id: id} = orphaned_task()
      assert {:ok, record} = store.get(id)
      assert TrackingStore.sealed?(record)

      adopt_and_preempt(id)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      assert {:ok, replacement} = store.get(new_id)
      assert TrackingStore.sealed?(replacement)
    end
  end

  describe "a rewrite of a record that is not signed" do
    test "a claim does not sign it", %{tmp_dir: dir} do
      store = start_ecto!(dir)
      %{id: id} = orphaned_task()
      TestOrchestrator.put_env(reap_owner: "m2")
      {:ok, record} = store.get(id)
      put_row!(record |> Map.delete(:mac) |> Map.put(:owner, nil))

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert {:ok, %{owner: "m2"} = claimed} = store.get(id)
      refute TrackingStore.sealed?(claimed)
    end

    test "control: a claim of a signed record keeps it signed", %{tmp_dir: dir} do
      store = start_ecto!(dir)
      %{id: id} = orphaned_task()
      TestOrchestrator.put_env(reap_owner: "m2")
      {:ok, record} = store.get(id)
      :ok = store.put(TrackingStore.seal(Map.put(record, :owner, nil)))

      :ok = Adopter.run(notify: self())
      assert_receive :adoption_complete, 2_000

      assert {:ok, %{owner: "m2"} = claimed} = store.get(id)
      assert TrackingStore.sealed?(claimed)
    end
  end
end
