defmodule ExAtlas.Spec.JobRequest do
  @moduledoc "Provider-agnostic request to run a serverless inference job."

  @enforce_keys [:endpoint, :input]
  defstruct endpoint: nil,
            input: nil,
            mode: :async,
            timeout_ms: 30_000,
            webhook: nil,
            policy: %{},
            provider_opts: %{}

  @type mode :: :async | :sync | :stream

  @type t :: %__MODULE__{
          endpoint: String.t(),
          input: term(),
          mode: mode(),
          timeout_ms: pos_integer(),
          webhook: String.t() | nil,
          policy: map(),
          provider_opts: map()
        }

  @schema [
    endpoint: [type: :string, required: true],
    input: [type: :any, required: true],
    mode: [type: {:in, [:async, :sync, :stream]}, default: :async],
    timeout_ms: [type: :pos_integer, default: 30_000],
    webhook: [type: {:or, [:string, nil]}, default: nil],
    policy: [type: :map, default: %{}],
    provider_opts: [type: :map, default: %{}]
  ]

  def new!(opts) do
    opts = opts |> normalize() |> NimbleOptions.validate!(@schema)
    struct!(__MODULE__, opts)
  end

  def new(opts) do
    with opts <- normalize(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  defp normalize(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize(opts) when is_list(opts), do: opts
end
