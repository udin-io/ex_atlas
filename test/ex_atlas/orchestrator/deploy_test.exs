defmodule ExAtlas.Orchestrator.DeployTest do
  @moduledoc """
  The scenario issue #23 is about, end to end through the real supervision
  tree: a task is running, the app is deployed, and the task must survive.

  Everything else in this suite tests a piece. This one starts
  `ExAtlas.Application`'s actual child list — same modules, same order — takes
  it down the way a deploy does, brings it back, and asks whether the training
  run is still there.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, Events, Reaper, TrackingStore}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:ex_atlas, :start_orchestrator, true)
    Application.put_env(:ex_atlas, :default_provider, :mock)
    Application.put_env(:ex_atlas, :callback, secret: TestOrchestrator.callback_secret())

    Application.put_env(:ex_atlas, :orchestrator,
      tracking_store: TrackingStore.Dets,
      storage_path: dir,
      reap_providers: [:mock],
      reap_grace_ms: 0
    )

    Mock.reset()

    on_exit(fn ->
      Application.delete_env(:ex_atlas, :start_orchestrator)
      Application.delete_env(:ex_atlas, :default_provider)
      Application.delete_env(:ex_atlas, :callback)
      Application.delete_env(:ex_atlas, :orchestrator)
    end)

    :ok
  end

  test "a deployed-over task is adopted rather than reaped" do
    boot()

    {:ok, tracker, compute} =
      Orchestrator.run_task(
        provider: :mock,
        gpu: :h100,
        image: "ghcr.io/acme/trainer:latest",
        command: ["/app/train.sh"],
        name: "atlas-train-42",
        max_runtime_ms: 6 * 60 * 60 * 1_000,
        status_poll_ms: false,
        persist: true
      )

    # A deploy does not let the trackers say goodbye — the machine goes away.
    # A brutal kill is the same thing from this pod's point of view: it keeps
    # running, and it keeps billing.
    ref = Process.monitor(tracker)
    Process.exit(tracker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^tracker, :killed}, 2_000

    shutdown()
    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)

    boot()

    # Back under a tracker, on the same id, with the deadline it was rented on.
    assert {:ok, %{compute: %{id: id}, max_runtime_remaining_ms: remaining}} =
             Orchestrator.info(compute.id)

    assert id == compute.id
    assert remaining <= 6 * 60 * 60 * 1_000

    # And the Reaper, which lists exactly this pod as running, prefix-matching
    # and past its grace window, now finds a tracker for it and leaves it
    # alone. (That an *unadopted* record also spares it is covered by
    # `ExAtlas.Orchestrator.ReaperTest`.)
    :ok = Reaper.reap_now("atlas-", [:mock])
    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  # `stop_supervised!/1` sends the tree the same `:shutdown` exit that
  # `init:stop/0` sends on SIGTERM, so every tracker's `terminate/2` runs.
  describe "a graceful stop (SIGTERM)" do
    test "keeps a persisted task's pod, and the next boot adopts it" do
      boot()
      {:ok, _tracker, compute} = run_task(persist: true)

      shutdown()
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)

      boot()
      assert {:ok, %{compute: %{id: id}}} = Orchestrator.info(compute.id)
      assert id == compute.id

      :ok = Reaper.reap_now("atlas-", [:mock])
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "deletes an unpersisted task's pod" do
      boot()
      {:ok, _tracker, compute} = run_task(persist: false)

      shutdown()
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "deletes an interactive session's pod" do
      boot()

      {:ok, _tracker, compute} =
        Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "ghcr.io/acme/notebook:latest",
          name: "atlas-session-7",
          status_poll_ms: false
        )

      shutdown()
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "deletes a persisted task's pod once its container reported an exit code" do
      boot()

      {:ok, _tracker, compute} =
        run_task(
          persist: true,
          callback: "https://app.example.com/atlas/cb",
          finish_grace_ms: 60_000
        )

      # Subscribing links this process to the PubSub registry, which the tree
      # stop below takes down with it.
      Process.flag(:trap_exit, true)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {:ok, %{callback_task_id: task_id}} = TrackingStore.Dets.get(compute.id)
      :ok = ExAtlas.Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      id = compute.id
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000

      shutdown()
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
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

  defp boot do
    children = ExAtlas.Application.orchestrator_children()

    sup =
      start_supervised!(%{
        id: :atlas_orchestrator_tree,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

    await_adoption(sup)
    sup
  end

  defp shutdown, do: stop_supervised!(:atlas_orchestrator_tree)

  # The Adopter is a transient Task: it exits `:normal` when it is done, so
  # waiting for it is a monitor rather than a sleep. A pid that has already
  # gone delivers `:DOWN` immediately, and `:undefined` means it finished
  # before we looked.
  defp await_adoption(sup) do
    case List.keyfind(Supervisor.which_children(sup), Adopter, 0) do
      {Adopter, pid, _type, _mods} when is_pid(pid) ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      _already_finished ->
        :ok
    end
  end
end
