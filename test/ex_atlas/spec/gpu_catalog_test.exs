defmodule ExAtlas.Spec.GpuCatalogTest do
  use ExUnit.Case, async: true
  doctest ExAtlas.Spec.GpuCatalog

  alias ExAtlas.Spec.GpuCatalog

  test "lists supported GPUs for RunPod" do
    gpus = GpuCatalog.supported_gpus(:runpod)
    assert :h100 in gpus
    assert :rtx_4090 in gpus
  end

  test "unknown providers return empty supported list" do
    assert GpuCatalog.supported_gpus(:bogus) == []
  end

  test "all_canonical returns a stable sorted union" do
    all = GpuCatalog.all_canonical()
    assert all == Enum.sort(all)
    assert :h100 in all
    assert Enum.uniq(all) == all
  end
end
