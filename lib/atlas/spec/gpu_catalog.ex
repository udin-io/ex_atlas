defmodule Atlas.Spec.GpuCatalog do
  @moduledoc """
  Canonical GPU atoms mapped to each provider's native identifier.

  Atlas refers to GPUs by a stable, provider-agnostic atom (`:h100`, `:a100_80g`,
  `:rtx_4090`, ...). Providers translate the canonical atom into whatever
  identifier their API expects when building a spawn request.

  New providers register their mapping here by extending the `@providers` map.
  """

  @type canonical :: atom()
  @type provider :: :runpod | :fly | :lambda_labs | :vast | :mock | module()

  @canonical_to_runpod %{
    h200: "NVIDIA H200",
    h100: "NVIDIA H100 80GB HBM3",
    h100_pcie: "NVIDIA H100 PCIe",
    a100_80g: "NVIDIA A100 80GB PCIe",
    a100_40g: "NVIDIA A100-SXM4-40GB",
    l40s: "NVIDIA L40S",
    l40: "NVIDIA L40",
    l4: "NVIDIA L4",
    a6000: "NVIDIA RTX A6000",
    a5000: "NVIDIA RTX A5000",
    a4000: "NVIDIA RTX A4000",
    rtx_6000_ada: "NVIDIA RTX 6000 Ada Generation",
    rtx_4090: "NVIDIA GeForce RTX 4090",
    rtx_3090: "NVIDIA GeForce RTX 3090",
    mi300x: "AMD Instinct MI300X OAM"
  }

  @canonical_to_lambda %{
    h100: "gpu_1x_h100_pcie",
    h100_sxm: "gpu_1x_h100_sxm5",
    a100_80g: "gpu_1x_a100_sxm4_80gb",
    a100_40g: "gpu_1x_a100_sxm4",
    a10: "gpu_1x_a10",
    a6000: "gpu_1x_a6000",
    rtx_6000: "gpu_1x_rtx_6000"
  }

  @canonical_to_fly %{
    a100_80g: "a100-80gb",
    a100_40g: "a100-pcie-40gb",
    l40s: "l40s",
    a10: "a10"
  }

  @canonical_to_vast %{
    h200: "H200",
    h100: "H100",
    a100_80g: "A100_80GB",
    a100_40g: "A100",
    rtx_4090: "RTX_4090",
    rtx_3090: "RTX_3090",
    a6000: "RTX_A6000"
  }

  @providers %{
    runpod: @canonical_to_runpod,
    lambda_labs: @canonical_to_lambda,
    fly: @canonical_to_fly,
    vast: @canonical_to_vast
  }

  @doc """
  Translate a canonical GPU atom to the provider-specific identifier.

  Returns `{:ok, id}` when the mapping exists, or `{:error, {:unsupported_gpu, gpu, provider}}`.

  ## Examples

      iex> Atlas.Spec.GpuCatalog.for_provider(:h100, :runpod)
      {:ok, "NVIDIA H100 80GB HBM3"}

      iex> Atlas.Spec.GpuCatalog.for_provider(:h100, :lambda_labs)
      {:ok, "gpu_1x_h100_pcie"}

      iex> Atlas.Spec.GpuCatalog.for_provider(:nonexistent, :runpod)
      {:error, {:unsupported_gpu, :nonexistent, :runpod}}
  """
  @spec for_provider(canonical(), provider()) :: {:ok, String.t()} | {:error, term()}
  def for_provider(canonical, provider) when is_atom(canonical) and is_atom(provider) do
    with {:ok, map} <- Map.fetch(@providers, provider),
         {:ok, id} <- Map.fetch(map, canonical) do
      {:ok, id}
    else
      :error -> {:error, {:unsupported_gpu, canonical, provider}}
    end
  end

  @doc "List the GPU atoms known for a provider."
  @spec supported_gpus(provider()) :: [canonical()]
  def supported_gpus(provider) do
    @providers |> Map.get(provider, %{}) |> Map.keys()
  end

  @doc "List every canonical GPU atom Atlas knows about, across all providers."
  @spec all_canonical() :: [canonical()]
  def all_canonical do
    @providers
    |> Map.values()
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
