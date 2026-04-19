defmodule Atlas.Orchestrator.ComputeServerTest do
  use ExUnit.Case, async: false

  alias Atlas.Orchestrator.{ComputeRegistry, ComputeSupervisor, Events}
  alias Atlas.Providers.Mock

  setup do
    Application.put_env(:atlas, :start_orchestrator, true)
    Application.put_env(:atlas, :default_provider, :mock)
    Mock.reset()

    start_supervised!({Registry, keys: :unique, name: ComputeRegistry})
    start_supervised!({DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one})

    if Code.ensure_loaded?(Phoenix.PubSub) do
      start_supervised!({Phoenix.PubSub, name: Atlas.PubSub})
    end

    on_exit(fn ->
      Application.delete_env(:atlas, :start_orchestrator)
      Application.delete_env(:atlas, :default_provider)
    end)

    :ok
  end

  test "spawn → touch → terminate teardown calls provider terminate" do
    {:ok, pid, compute} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    assert Process.alive?(pid)
    assert {:ok, _} = Atlas.Orchestrator.info(compute.id)
    :ok = Atlas.Orchestrator.touch(compute.id)

    ref = Process.monitor(pid)
    :ok = Atlas.Orchestrator.stop_tracked(compute.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    # Upstream terminate was called
    {:ok, gone} = Atlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "idle timeout triggers termination" do
    if Code.ensure_loaded?(Phoenix.PubSub), do: Phoenix.PubSub.subscribe(Atlas.PubSub, "compute:")

    {:ok, pid, compute} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 10,
        heartbeat_ms: 10
      )

    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Phoenix.PubSub.subscribe(Atlas.PubSub, Events.topic(compute.id))

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    {:ok, gone} = Atlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "touch resets the idle timer" do
    {:ok, pid, compute} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 200,
        heartbeat_ms: 50
      )

    _ref = Process.monitor(pid)

    # Keep touching faster than the idle ttl — server must stay alive
    Enum.each(1..4, fn _ ->
      Process.sleep(50)
      :ok = Atlas.Orchestrator.touch(compute.id)
    end)

    assert Process.alive?(pid)

    # Now stop touching — should die
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end
end
