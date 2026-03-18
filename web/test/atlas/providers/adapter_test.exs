defmodule Atlas.Providers.AdapterTest do
  use ExUnit.Case, async: true

  alias Atlas.Providers.Adapter

  describe "adapter_for/1" do
    test "returns Fly adapter for :fly" do
      assert {:ok, Atlas.Providers.Adapters.Fly} = Adapter.adapter_for(:fly)
    end

    test "returns RunPod adapter for :runpod" do
      assert {:ok, Atlas.Providers.Adapters.RunPod} = Adapter.adapter_for(:runpod)
    end

    test "returns error for unknown provider" do
      assert {:error, :unknown_provider} = Adapter.adapter_for(:unknown)
    end
  end
end
