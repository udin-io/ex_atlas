defmodule ExAtlas.Spec.TemplateRequest do
  @moduledoc """
  Provider-agnostic request for a template: a saved image, ports, env and disk
  that `ExAtlas.spawn_compute/1` reuses through `template_id:`.

  `:ports` take the same `{port, :http | :tcp}` tuples as
  `ExAtlas.Spec.ComputeRequest`. `:ssh` and `:jupyter` left at `nil` leave the
  provider's own default in force (RunPod turns both on).

  `inspect/1` leaves out `:env`, which holds secrets, and an invalid `:env`
  is an error that names the key and holds no value.
  """

  alias ExAtlas.Spec.Env

  @derive {Inspect, except: [:env]}
  @enforce_keys [:name, :image]
  defstruct name: nil,
            image: nil,
            ports: [],
            env: %{},
            container_disk_gb: nil,
            volume_gb: nil,
            command: nil,
            serverless: false,
            ssh: nil,
            jupyter: nil,
            provider_opts: %{}

  @type t :: %__MODULE__{
          name: String.t(),
          image: String.t(),
          ports: [{:inet.port_number(), :http | :tcp}],
          env: %{optional(String.t()) => String.t()},
          container_disk_gb: pos_integer() | nil,
          volume_gb: pos_integer() | nil,
          command: [String.t()] | nil,
          serverless: boolean(),
          ssh: boolean() | nil,
          jupyter: boolean() | nil,
          provider_opts: map()
        }

  @schema [
    name: [type: :string, required: true],
    image: [type: :string, required: true],
    ports: [type: {:list, :any}, default: []],
    # Checked by `Env.validate/1`: NimbleOptions puts the env in its error.
    env: [type: :any, default: %{}],
    container_disk_gb: [type: {:or, [:pos_integer, nil]}, default: nil],
    volume_gb: [type: {:or, [:pos_integer, nil]}, default: nil],
    command: [type: {:or, [{:list, :string}, nil]}, default: nil],
    serverless: [type: :boolean, default: false],
    ssh: [type: {:or, [:boolean, nil]}, default: nil],
    jupyter: [type: {:or, [:boolean, nil]}, default: nil],
    provider_opts: [type: :map, default: %{}]
  ]

  @doc "Build a validated `TemplateRequest` from keyword opts. Raises on invalid input."
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case new(opts) do
      {:ok, request} -> request
      {:error, error} -> raise error
    end
  end

  @doc "Build a validated `TemplateRequest` from keyword opts."
  @spec new(keyword()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) when is_list(opts) do
    with {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         :ok <- Env.validate(opts[:env]) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end
end
