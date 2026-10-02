defmodule ExAtlas.Spec.GpuCatalogTest do
  use ExUnit.Case, async: true
  doctest ExAtlas.Spec.GpuCatalog

  alias ExAtlas.Spec.GpuCatalog

  test "lists supported GPUs for RunPod" do
    gpus = GpuCatalog.supported_gpus(:runpod)
    assert :h100 in gpus
    assert :rtx_4090 in gpus
  end

  # Lambda's own names: the 1x form is the family key, even where Lambda sells
  # only the 8x type (A100 80 GB).
  test "maps Lambda GPUs to the instance type names Lambda lists" do
    assert GpuCatalog.for_provider(:rtx_6000, :lambda_labs) == {:ok, "gpu_1x_rtx6000"}
    assert GpuCatalog.for_provider(:a100_80g, :lambda_labs) == {:ok, "gpu_1x_a100_80gb_sxm4"}
    assert GpuCatalog.for_provider(:gh200, :lambda_labs) == {:ok, "gpu_1x_gh200"}
  end

  # Vast's API takes its spaced names. `RTX_4090`, the form vast-cli's help
  # shows, matches no offer.
  test "maps Vast GPUs to Vast's spaced names, one per variant" do
    assert GpuCatalog.for_provider(:rtx_4090, :vast) == {:ok, ["RTX 4090"]}
    assert GpuCatalog.for_provider(:h100, :vast) == {:ok, ["H100 SXM", "H100 PCIE", "H100 NVL"]}
    assert GpuCatalog.for_provider(:a6000, :vast) == {:ok, ["RTX A6000"]}

    for gpu <- GpuCatalog.supported_gpus(:vast),
        {:ok, names} = GpuCatalog.for_provider(gpu, :vast),
        name <- names do
      refute name =~ "_", "#{inspect(gpu)} maps to #{inspect(name)}"
    end
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
