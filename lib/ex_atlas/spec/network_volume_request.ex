defmodule ExAtlas.Spec.NetworkVolumeRequest do
  @moduledoc """
  Provider-agnostic request for a network volume.

  `:region` is optional here because not every provider needs one. RunPod
  does: its translator returns a `:validation` error when `:region` is unset.
  `:tier` unset leaves the choice to the provider.
  """

  @enforce_keys [:name, :size_gb]
  defstruct name: nil, size_gb: nil, region: nil, tier: nil, provider_opts: %{}

  @type tier :: :standard | :high_performance

  @type t :: %__MODULE__{
          name: String.t(),
          size_gb: pos_integer(),
          region: String.t() | nil,
          tier: tier() | nil,
          provider_opts: map()
        }

  @schema [
    name: [type: :string, required: true],
    size_gb: [type: :pos_integer, required: true],
    region: [type: {:or, [:string, nil]}, default: nil],
    tier: [type: {:or, [{:in, [:standard, :high_performance]}, nil]}, default: nil],
    provider_opts: [type: :map, default: %{}]
  ]

  @doc "Build a validated `NetworkVolumeRequest` from keyword opts. Raises on invalid input."
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    struct!(__MODULE__, opts)
  end

  @doc "Build a validated `NetworkVolumeRequest` from keyword opts."
  @spec new(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) when is_list(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end
end
