defmodule ExAtlas.Orchestrator.SupervisorTest do
  @moduledoc """
  The host starts `ExAtlas.Orchestrator.Supervisor` after its own repo, so the
  Ecto tracking store can be read at boot. Each test builds that host tree,
  `[ExAtlas.Test.Repo, ExAtlas.Orchestrator.Supervisor]`, on a SQLite file of
  its own, and takes it down and up the way a deploy does.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Reaper}
  alias ExAtlas.Orchestrator.Supervisor, as: OrchestratorSupervisor
  alias ExAtlas.Orchestrator.TrackingStore.Ecto, as: Store
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
  alias ExAtlas.Test.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    database = Repo.start!(dir)
    stop_supervised!(Repo)

    Application.put_env(:ex_atlas, :start_orchestrator, false)
    Application.put_env(:ex_atlas, :default_provider, :mock)
    Application.put_env(:ex_atlas, :callback, secret: TestOrchestrator.callback_secret())

    TestOrchestrator.put_env(
      tracking_store: Store,
      reap_providers: [:mock],
      reap_grace_ms: 0,
      reap_interval_ms: :timer.hours(1)
    )

    Mock.reset()

    on_exit(fn ->
      Application.delete_env(:ex_atlas, :start_orchestrator)
      Application.delete_env(:ex_atlas, :default_provider)
      Application.delete_env(:ex_atlas, :callback)
    end)

    {:ok, database: database}
  end

  test "serves spawn/1 and list_ids/0 with start_orchestrator: false", %{database: db} do
    boot(db)

    {:ok, _pid, compute} =
      Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x", name: "atlas-s")

    assert Orchestrator.list_ids() == [compute.id]
  end

  test "a deployed-over task is adopted from the Ecto store, and the Reaper opens",
       %{database: db} do
    boot(db)
    {:ok, tracker, compute} = run_task(persist: true)

    # A deploy does not let the tracker say goodbye.
    ref = Process.monitor(tracker)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}, 2_000
    shutdown()

    boot(db)

    assert Orchestrator.list_ids() == [compute.id]

    # The Adopter sent :adoption_complete: a tick reaps an untracked pod, and
    # leaves the adopted one running.
    {:ok, orphan} = spawn_untracked()
    :ok = tick()

    assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(orphan.id, provider: :mock)
    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a row that will not decode adopts nothing and reaps nothing that boot",
       %{database: db} do
    with_repo(db, fn ->
      Repo.query!(
        "INSERT INTO atlas_tracking_records (id, owner, record, inserted_at, updated_at) " <>
          "VALUES ('pod-x', NULL, ?1, '2026-10-02T00:00:00Z', '2026-10-02T00:00:00Z')",
        [{:blob, "not an external term"}]
      )
    end)

    boot(db)
    {:ok, orphan} = spawn_untracked()
    :ok = tick()

    assert Orchestrator.list_ids() == []
    assert {:ok, %{status: :running}} = ExAtlas.get_compute(orphan.id, provider: :mock)
  end

  test "stopping the supervisor keeps a persisted task's row", %{database: db} do
    boot(db)
    {:ok, _tracker, compute} = run_task(persist: true)

    shutdown()

    with_repo(db, fn ->
      assert {:ok, %{id: id, mode: :task}} = Store.get(compute.id)
      assert id == compute.id
    end)
  end

  # The supervisor stops before the repo, so a tracker can still write as it
  # stops: a task that reported deletes its row on the way out.
  test "stopping the supervisor lets a reported task delete its row", %{database: db} do
    boot(db)

    {:ok, _tracker, compute} =
      run_task(
        persist: true,
        callback: "https://app.example.com/atlas/cb",
        finish_grace_ms: 60_000
      )

    id = compute.id
    Phoenix.PubSub.subscribe(ExAtlas.PubSub, ExAtlas.Orchestrator.Events.topic(id))
    {:ok, %{callback_task_id: task_id}} = Store.get(id)
    :ok = ExAtlas.Callback.ingest(task_id, :finish, %{"exit_code" => 0})
    assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
    # The PubSub registry links to its subscribers and stops with the tree.
    Phoenix.PubSub.unsubscribe(ExAtlas.PubSub, ExAtlas.Orchestrator.Events.topic(id))

    shutdown()

    with_repo(db, fn -> assert :error = Store.get(id) end)
    assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
  end

  # 0.8.0 wrote no `:respawning` (#115); a later record may hold nil.
  test "adopts a record without :respawning, and one with nil", %{database: db} do
    boot(db)
    {:ok, _t1, old} = run_task(persist: true, name: "atlas-train-old")
    {:ok, _t2, new} = run_task(persist: true, name: "atlas-train-nil")
    shutdown()

    with_repo(db, fn ->
      {:ok, old_record} = Store.get(old.id)
      :ok = Store.put(Map.delete(old_record, :respawning))
      {:ok, new_record} = Store.get(new.id)
      :ok = Store.put(%{new_record | respawning: nil})
    end)

    boot(db)

    assert Enum.sort(Orchestrator.list_ids()) == Enum.sort([old.id, new.id])
  end

  test "refuses to start when start_orchestrator: true, naming both settings" do
    Application.put_env(:ex_atlas, :start_orchestrator, true)

    error = assert_raise ArgumentError, fn -> OrchestratorSupervisor.start_link([]) end
    assert error.message =~ "start_orchestrator: true"
    assert error.message =~ "ExAtlas.Orchestrator.Supervisor"
  end

  test "refuses to start before the host's repo", %{database: db} do
    children = [OrchestratorSupervisor, {Repo, database: db, log: false}]

    assert {:error, reason} =
             start_supervised(%{
               id: :host,
               start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
               type: :supervisor
             })

    assert inspect(reason) =~ "ExAtlas.Test.Repo is not running"
    refute Process.whereis(ExAtlas.Orchestrator.ComputeSupervisor)
  end

  # ExAtlas's own application boots before the host's repo, so this pairing
  # would come up with no store every boot.
  test "start_orchestrator: true with the Ecto store refuses to boot ExAtlas's tree" do
    Application.put_env(:ex_atlas, :start_orchestrator, true)
    children = ExAtlas.Application.orchestrator_children()

    assert {:error, reason} =
             start_supervised(%{
               id: :atlas_tree,
               start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
               type: :supervisor
             })

    assert inspect(reason) =~ "ExAtlas.Test.Repo is not running"
  end

  test "spawn/1 with no tree running raises, naming both ways to start it" do
    error =
      assert_raise RuntimeError, fn ->
        Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x", name: "atlas-s")
      end

    assert error.message =~ "start_orchestrator: true"
    assert error.message =~ "ExAtlas.Orchestrator.Supervisor"
  end

  defp boot(database) do
    sup =
      start_supervised!(%{
        id: :host,
        start:
          {Supervisor, :start_link,
           [
             [{Repo, database: database, log: false}, OrchestratorSupervisor],
             [strategy: :one_for_one]
           ]},
        type: :supervisor
      })

    await_adoption()
    sup
  end

  defp shutdown, do: stop_supervised!(:host)

  defp with_repo(database, fun) do
    start_supervised!({Repo, database: database, log: false})
    fun.()
    stop_supervised!(Repo)
  end

  defp await_adoption do
    case List.keyfind(Supervisor.which_children(OrchestratorSupervisor), Adopter, 0) do
      {Adopter, pid, _type, _mods} when is_pid(pid) ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      _already_finished ->
        :ok
    end
  end

  defp tick do
    reaper = Process.whereis(Reaper)
    send(reaper, :reap)
    _ = :sys.get_state(reaper)
    :ok
  end

  defp spawn_untracked do
    ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", name: "atlas-orphan")
  end

  defp run_task(overrides) do
    Orchestrator.run_task(
      Keyword.merge(
        [
          provider: :mock,
          gpu: :h100,
          image: "ghcr.io/acme/trainer:latest",
          command: ["/app/train.sh"],
          name: "atlas-train-42",
          max_runtime_ms: 6 * 60 * 60 * 1_000,
          status_poll_ms: false
        ],
        overrides
      )
    )
  end
end
