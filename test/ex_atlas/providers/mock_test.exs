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
end
