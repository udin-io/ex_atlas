defmodule ExAtlas.Spec.ComputeRequest do
  @moduledoc """
  Provider-agnostic request for a compute resource (pod/machine/instance).

  Fields that a given provider doesn't natively support are simply ignored by
  that provider's translator. Fields unique to a provider can be passed through
  `:provider_opts`.

  ## Running a command to completion

  `:command` overrides the image's start command (RunPod's `dockerStartCmd`),
  which is how you run batch work rather than a long-lived service:

      command: ["/app/train.sh", "--epochs", "3"]

  `:self_terminate` (default `true`, and only meaningful alongside `:command`)
  asks the provider's translator to wrap that command in a shell that destroys
  the resource once it ends — on a clean exit, a non-zero exit, or a signal.

  It defaults to on because the alternative is a bill. RunPod's REST API
  exposes no container state at all: when `dockerStartCmd` exits the pod stays
  `desiredStatus: "RUNNING"`, the GPU stays reserved, and nothing polling the
  API can tell the difference. Self-termination is the only thing that turns a
  finished container into an observable event.

  Set `self_terminate: false` for an image with no shell or no `curl`, or when
  you want to keep the resource up for inspection after the command ends. Then
  the only thing that will ever stop it is
  `ExAtlas.Orchestrator.run_task/1`'s `:max_runtime_ms`, or you — unless a
  `:callback` is configured, in which case the container still reports its exit
  code and `:finish_grace_ms` ends the task on that.

  ## Reporting back

  `:callback` is not set by hand. `ExAtlas.Orchestrator.spawn/1` builds it from
  the `callback: url` spawn option (see `ExAtlas.Callback.prepare/1`) and it
  carries the `task_id` the pod's credential is bound to. A provider translator
  expands it into `ATLAS_CALLBACK_URL`, `ATLAS_CALLBACK_TOKEN` and
  `ATLAS_TASK_ID` in the container environment.
  """

  @enforce_keys [:gpu]
  defstruct gpu: nil,
            gpu_count: 1,
            image: nil,
            cloud_type: :any,
            spot: false,
            region_hints: [],
            ports: [],
            env: %{},
            volume_gb: nil,
            container_disk_gb: nil,
            network_volume_id: nil,
            name: nil,
            template_id: nil,
            auth: :none,
            idle_ttl_ms: nil,
            command: nil,
            self_terminate: true,
            callback: nil,
            provider_opts: %{}

  @type port_spec :: {pos_integer(), :http | :tcp}
  @type cloud_type :: :secure | :community | :any
  @type auth_scheme :: :none | :bearer | :signed_url

  @type t :: %__MODULE__{
          gpu: atom(),
          gpu_count: pos_integer(),
          image: String.t() | nil,
          cloud_type: cloud_type(),
          spot: boolean(),
          region_hints: [String.t()],
          ports: [port_spec()],
          env: %{optional(String.t()) => String.t()},
          volume_gb: pos_integer() | nil,
          container_disk_gb: pos_integer() | nil,
          network_volume_id: String.t() | nil,
          name: String.t() | nil,
          template_id: String.t() | nil,
          auth: auth_scheme(),
          idle_ttl_ms: pos_integer() | nil,
          command: [String.t()] | nil,
          self_terminate: boolean(),
          callback: ExAtlas.Callback.config() | nil,
          provider_opts: map()
        }

  @schema [
    gpu: [type: :atom, required: true],
    gpu_count: [type: :pos_integer, default: 1],
    image: [type: {:or, [:string, nil]}, default: nil],
    cloud_type: [type: {:in, [:secure, :community, :any]}, default: :any],
    spot: [type: :boolean, default: false],
    region_hints: [type: {:list, :string}, default: []],
    ports: [type: {:list, :any}, default: []],
    env: [type: {:map, :string, :string}, default: %{}],
    volume_gb: [type: {:or, [:pos_integer, nil]}, default: nil],
    container_disk_gb: [type: {:or, [:pos_integer, nil]}, default: nil],
    network_volume_id: [type: {:or, [:string, nil]}, default: nil],
    name: [type: {:or, [:string, nil]}, default: nil],
    template_id: [type: {:or, [:string, nil]}, default: nil],
    auth: [type: {:in, [:none, :bearer, :signed_url]}, default: :none],
    idle_ttl_ms: [type: {:or, [:pos_integer, nil]}, default: nil],
    command: [type: {:or, [{:list, :string}, nil]}, default: nil],
    self_terminate: [type: :boolean, default: true],
    callback: [type: {:or, [:map, nil]}, default: nil],
    provider_opts: [type: :map, default: %{}]
  ]

  @doc "Build a validated `ComputeRequest` from keyword opts. Raises on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    opts = opts |> normalize() |> NimbleOptions.validate!(@schema)
    struct!(__MODULE__, opts)
  end

  @doc "Build a validated `ComputeRequest` from keyword opts."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) do
    with opts <- normalize(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, @schema) do
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  defp normalize(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize(opts) when is_list(opts), do: opts
end
