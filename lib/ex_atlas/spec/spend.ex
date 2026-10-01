defmodule ExAtlas.Spec.Spend do
  @moduledoc """
  One compute resource's spend in US dollars, returned by
  `ExAtlas.compute_spend/2`.

  `from` and `to` are the window the totals cover, `[from, to)`, as the
  provider resolved it. They are `nil` when the provider's answer carries no
  window. `raw` holds the provider's own body, per-bucket records included.
  """

  @enforce_keys [:compute_id, :provider]
  defstruct compute_id: nil,
            provider: nil,
            total_usd: nil,
            gpu_usd: nil,
            cpu_usd: nil,
            disk_usd: nil,
            from: nil,
            to: nil,
            raw: %{}

  @type t :: %__MODULE__{
          compute_id: String.t(),
          provider: atom(),
          total_usd: float() | nil,
          gpu_usd: float() | nil,
          cpu_usd: float() | nil,
          disk_usd: float() | nil,
          from: DateTime.t() | nil,
          to: DateTime.t() | nil,
          raw: map()
        }
end
