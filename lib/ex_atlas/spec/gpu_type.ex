defmodule ExAtlas.Spec.GpuType do
  @moduledoc "Normalized GPU type + pricing entry returned by `list_gpu_types/1`."

  @enforce_keys [:id, :provider]
  defstruct id: nil,
            provider: nil,
            canonical: nil,
            display_name: nil,
            memory_gb: nil,
            lowest_price_per_hour: nil,
            spot_price_per_hour: nil,
            stock: nil,
            cloud_type: nil,
            raw: %{}

  @type stock :: :high | :medium | :low | :unavailable | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          canonical: atom() | nil,
          display_name: String.t() | nil,
          memory_gb: pos_integer() | nil,
          lowest_price_per_hour: float() | nil,
          spot_price_per_hour: float() | nil,
          stock: stock() | nil,
          cloud_type: :secure | :community | :any | nil,
          raw: map()
        }
end
