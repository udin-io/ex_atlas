defmodule ExAtlas.Providers.MockTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: :mock,
    reset: {ExAtlas.Providers.Mock, :reset, []}

  alias ExAtlas.Providers.Mock

  describe "simulating upstream state changes" do
    setup do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, compute: compute}
    end

    test "set_status/2 is reflected by get_compute/2", %{compute: compute} do
      assert :ok = Mock.set_status(compute.id, :failed)
      assert {:ok, %{status: :failed}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "set_status/2 on an unknown id reports :not_found" do
      assert {:error, %ExAtlas.Error{kind: :not_found}} = Mock.set_status("nope", :failed)
    end

    test "forget/1 makes the resource vanish the way a deleted pod does", %{compute: compute} do
      assert :ok = Mock.forget(compute.id)

      assert {:error, %ExAtlas.Error{kind: :not_found}} =
               ExAtlas.get_compute(compute.id, provider: :mock)

      assert {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      refute Enum.any?(computes, &(&1.id == compute.id))
    end

    test "forget/1 is idempotent" do
      assert :ok = Mock.forget("never-existed")
    end
  end

  describe "the hourly price" do
    test "a spawn costs 0.0 per hour unless provider_opts names a price" do
      {:ok, free} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      assert free.cost_per_hour == 0.0

      {:ok, priced} =
        ExAtlas.spawn_compute(
          provider: :mock,
          gpu: :h100,
          image: "x",
          provider_opts: %{cost_per_hour: 2.99}
        )

      assert priced.cost_per_hour == 2.99
      assert {:ok, %{cost_per_hour: 2.99}} = ExAtlas.get_compute(priced.id, provider: :mock)
    end

    test "provider_opts can spawn a compute that reports no price" do
      {:ok, compute} =
        ExAtlas.spawn_compute(
          provider: :mock,
          gpu: :h100,
          image: "x",
          provider_opts: %{cost_per_hour: nil}
        )

      assert compute.cost_per_hour == nil
    end

    test "set_cost_per_hour/2 changes the price the next read reports" do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")

      assert :ok = Mock.set_cost_per_hour(compute.id, 3.29)
      assert {:ok, %{cost_per_hour: 3.29}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "set_cost_per_hour/2 on an unknown id reports :not_found" do
      assert {:error, %ExAtlas.Error{kind: :not_found}} = Mock.set_cost_per_hour("nope", 1.0)
    end
  end

  describe "billing" do
    setup do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, compute: compute}
    end

    test "reports :billing" do
      assert :billing in ExAtlas.capabilities(:mock)
    end

    test "a pod has billed nothing until set_spend/2", %{compute: %{id: id}} do
      assert {:ok, %ExAtlas.Spec.Spend{compute_id: ^id, provider: :mock, total_usd: +0.0}} =
               ExAtlas.compute_spend(id, provider: :mock)
    end

    test "set_spend/2 sets the total the next compute_spend reports", %{compute: %{id: id}} do
      from = ~U[2026-10-01 00:00:00Z]

      assert :ok = Mock.set_spend(id, 1.8)

      assert {:ok, %ExAtlas.Spec.Spend{total_usd: 1.8, from: ^from}} =
               ExAtlas.compute_spend(id, provider: :mock, from: from)
    end

    test "set_spend/2 bills a pod that is already gone", %{compute: %{id: id}} do
      :ok = Mock.forget(id)
      :ok = Mock.set_spend(id, 0.5)

      assert {:ok, %ExAtlas.Spec.Spend{total_usd: 0.5}} =
               ExAtlas.compute_spend(id, provider: :mock)
    end

    test "spend_calls/1 counts compute_spend calls per pod", %{compute: %{id: id}} do
      assert Mock.spend_calls(id) == 0

      {:ok, _} = ExAtlas.compute_spend(id, provider: :mock)
      {:ok, _} = ExAtlas.compute_spend(id, provider: :mock)
      {:ok, _} = ExAtlas.compute_spend("other", provider: :mock)

      assert Mock.spend_calls(id) == 2
    end
  end
end
