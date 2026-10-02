defmodule ExAtlas.Spec.Endpoint do
  @moduledoc """
  Normalized serverless endpoint returned by `ExAtlas.get_endpoint/2` and
  `ExAtlas.list_endpoints/1`.

  `gpu_pools` holds the provider's GPU pool ids (RunPod: `"ADA_24"`), not card
  names. `type` is `:unknown` for a type this library does not know and `nil`
  when the provider sent none. `raw` holds the provider's own body
  without `env` and without the `env` of its embedded `template` and
  `workers`: they hold secrets. `inspect/1` leaves `raw` out as well.
  """

  @derive {Inspect, except: [:raw]}
  @enforce_keys [:id, :provider]
  defstruct id: nil,
            provider: nil,
            name: nil,
            type: nil,
            workers_min: nil,
            workers_max: nil,
            gpu_pools: [],
            region_hints: [],
            network_volume_ids: [],
            created_at: nil,
            raw: %{}

  @type type :: :queue | :load_balancer | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          provider: atom(),
          name: String.t() | nil,
          type: type() | nil,
          workers_min: non_neg_integer() | nil,
          workers_max: non_neg_integer() | nil,
          gpu_pools: [String.t()],
          region_hints: [String.t()],
          network_volume_ids: [String.t()],
          created_at: DateTime.t() | nil,
          raw: map()
        }
end
