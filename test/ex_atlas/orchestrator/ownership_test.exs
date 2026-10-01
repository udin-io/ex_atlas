defmodule ExAtlas.Orchestrator.OwnershipTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.Events
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator

  setup do
    TestOrchestrator.start!()
    :ok
  end

  defp spawn_named(name, opts \\ []) do
    [
      provider: :mock,
      gpu: :h100,
      image: "x",
      name: name,
      idle_ttl_ms: 60_000,
      heartbeat_ms: 60_000,
      status_poll_ms: false
    ]
    |> Keyword.merge(opts)
    |> ExAtlas.Orchestrator.spawn()
  end

  defp provider_names do
    {:ok, computes} = ExAtlas.list_compute(provider: :mock)
    Enum.map(computes, & &1.name)
  end

  describe "with a :reap_owner" do
    setup do
      TestOrchestrator.put_env(reap_owner: "m1")
    end

    test "spawn/1 writes the owner into the name the caller and the provider see" do
      {:ok, _pid, compute} = spawn_named("atlas-train-42")

      assert compute.name == "atlas-m1-train-42"
      assert provider_names() == ["atlas-m1-train-42"]
    end

    test "a respawned replacement carries the owner too" do
      {:ok, _pid, compute} =
        spawn_named("atlas-train-42",
          spot: true,
          status_poll_ms: 30,
          on_failure: {:respawn, 1}
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Mock.forget(compute.id)

      assert_receive {:atlas_compute, _, {:respawned, new_id}}, 2_000
      assert {:ok, %{name: "atlas-m1-train-42"}} = ExAtlas.get_compute(new_id, provider: :mock)
    end

    test "a name without the prefix, or already stamped, is unchanged" do
      {:ok, _pid, foreign} = spawn_named("other-tool-pod")
      {:ok, _pid, stamped} = spawn_named("atlas-m1-train-42")

      assert foreign.name == "other-tool-pod"
      assert stamped.name == "atlas-m1-train-42"
    end
  end

  test "without a :reap_owner the name is unchanged" do
    {:ok, _pid, compute} = spawn_named("atlas-train-42")

    assert compute.name == "atlas-train-42"
    assert provider_names() == ["atlas-train-42"]
  end

  test "an invalid :reap_owner refuses spawn/1 and rents nothing" do
    # A dash would let owner "m1" match owner "m1-x"'s pods.
    TestOrchestrator.put_env(reap_owner: "m1-x")

    assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
             spawn_named("atlas-train-42")

    assert message =~ ":reap_owner"
    refute message =~ "m1-x"
    assert provider_names() == []
  end

  test "an owner set with no name prefix spawns the name unchanged" do
    TestOrchestrator.put_env(reap_owner: "m1", reap_name_prefix: nil)

    assert {:ok, _pid, %{name: "atlas-train-42"}} = spawn_named("atlas-train-42")
  end
end
