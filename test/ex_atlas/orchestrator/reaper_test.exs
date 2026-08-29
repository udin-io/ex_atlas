defmodule ExAtlas.Orchestrator.ReaperTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.Reaper
  alias ExAtlas.Test.FaultyProvider

  setup do
    ExAtlas.Test.Orchestrator.start!()
    on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)

    :ok
  end

  defp spawn_untracked(opts \\ []) do
    [provider: :mock, gpu: :h100, image: "x", name: "atlas-orphan"]
    |> Keyword.merge(opts)
    |> ExAtlas.spawn_compute()
  end

  test "an untracked resource past the grace window is reclaimed" do
    Application.put_env(:ex_atlas, :orchestrator, reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked()

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a resource whose name lacks the prefix is never touched" do
    Application.put_env(:ex_atlas, :orchestrator, reap_grace_ms: 0)
    {:ok, compute} = spawn_untracked(name: "someone-elses-pod")

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a tracked resource is never touched" do
    Application.put_env(:ex_atlas, :orchestrator, reap_grace_ms: 0)

    {:ok, _pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        name: "atlas-tracked",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: false
      )

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a resource younger than the grace window is left alone" do
    # No tracker yet is not the same as no tracker ever: `Orchestrator.spawn/1`
    # and the respawn path both create the resource before registering it.
    {:ok, compute} = spawn_untracked()

    :ok = Reaper.reap_now("atlas-", [:mock])

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end

  test "a resource is not reaped while its own spawn call is still in flight" do
    Application.put_env(:ex_atlas, :orchestrator, reap_grace_ms: 60_000)

    FaultyProvider.arm(:spawn_compute, {:block_after, self()})

    spawning =
      Task.async(fn ->
        ExAtlas.Orchestrator.spawn(
          provider: FaultyProvider,
          gpu: :h100,
          image: "x",
          name: "atlas-mid-spawn",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: false
        )
      end)

    # The provider has created the resource; the caller has not seen the reply,
    # so nothing is in the registry yet. This is the window the Reaper used to
    # walk straight into — and on the respawn path each tick it does so burns
    # one respawn from the budget.
    assert_receive {:blocked, :spawn_compute, provider_pid}, 2_000
    :ok = Reaper.reap_now("atlas-", [FaultyProvider])

    send(provider_pid, :release)
    assert {:ok, _pid, compute} = Task.await(spawning)

    assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
  end
end
