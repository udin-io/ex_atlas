defmodule Atlas.LiveDashboard.ComputePageTest do
  use ExUnit.Case, async: false

  alias Atlas.LiveDashboard.ComputePage
  alias Atlas.Orchestrator.{ComputeRegistry, ComputeSupervisor}
  alias Atlas.Providers.Mock

  setup do
    Application.put_env(:atlas, :start_orchestrator, true)
    Application.put_env(:atlas, :default_provider, :mock)
    Mock.reset()

    start_supervised!({Registry, keys: :unique, name: ComputeRegistry})
    start_supervised!({DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one})

    on_exit(fn ->
      Application.delete_env(:atlas, :start_orchestrator)
      Application.delete_env(:atlas, :default_provider)
    end)

    :ok
  end

  test "build_row/1 returns a map for a live resource" do
    {:ok, _pid, compute} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "test",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    row = ComputePage.build_row(compute.id)
    assert row.id == compute.id
    assert row.provider == ":mock"
    assert row.status == "running"
    assert row.gpu_type == "h100"
    assert is_integer(row.idle_for) or row.idle_for == 0
  end

  test "build_row/1 returns nil for unknown id" do
    assert ComputePage.build_row("does-not-exist") == nil
  end

  test "fetch_rows/2 filters by search and returns {rows, count}" do
    {:ok, _, a} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    {:ok, _, _b} =
      Atlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    {all, 2} =
      ComputePage.fetch_rows(%{search: nil, sort_by: :id, sort_dir: :asc, limit: 100}, node())

    assert length(all) == 2

    {filtered, 1} =
      ComputePage.fetch_rows(
        %{search: a.id, sort_by: :id, sort_dir: :asc, limit: 100},
        node()
      )

    assert [%{id: id}] = filtered
    assert id == a.id
  end

  test "init/1 declares the :atlas application requirement" do
    assert {:ok, _, application: :atlas} = ComputePage.init([])
  end

  test "menu_link/2 always shows 'Atlas'" do
    assert {:ok, "Atlas"} = ComputePage.menu_link(%{}, %{})
  end
end
