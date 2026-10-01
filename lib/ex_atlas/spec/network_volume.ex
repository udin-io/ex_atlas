defmodule ExAtlas.Spec.NetworkVolume do
  @moduledoc """
  Normalized network volume returned by `ExAtlas.create_network_volume/1`,
  `ExAtlas.get_network_volume/2` and `ExAtlas.list_network_volumes/1`.

  `raw` holds the provider's own body for the volume.
  """

  @enforce_keys [:id, :provider]
  defstruct id: nil,
            provider: nil,
            name: nil,
            size_gb: nil,
            region: nil,
            tier: nil,
            raw: %{}

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          name: String.t() | nil,
          size_gb: pos_integer() | nil,
          region: String.t() | nil,
          tier: ExAtlas.Spec.NetworkVolumeRequest.tier() | nil,
          raw: map()
        }
end
