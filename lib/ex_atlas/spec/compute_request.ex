defmodule ExAtlas.Spec.ComputeRequest do
  @moduledoc """
  Provider-agnostic request for a compute resource (pod/machine/instance).

  Fields that a given provider doesn't natively support are simply ignored by
  that provider's translator. Fields unique to a provider can be passed through
  `:provider_opts`.

  ## Running a command to completion

  `:command` overrides the image's start command (Runpod's `cmd`),
  which is how you run batch work rather than a long-lived service:

      command: ["/app/train.sh", "--epochs", "3"]

  `:self_terminate` (default `true`, and only meaningful alongside `:command`)
  asks the provider's translator to wrap that command in a shell that destroys
  the resource once it ends — on a clean exit, a non-zero exit, or a signal.

  It defaults to on because the alternative is a bill. Runpod's REST API
  exposes no exit code: when `cmd` exits the pod stays `status: "RUNNING"`
  (Runpod restarts the container), the GPU stays reserved, and nothing polling the
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

  ## Data staging

  `:s3` puts storage credentials and the dataset and artifact addresses into the
  container environment as `AWS_*` and `ATLAS_*` variables. See
  `ExAtlas.Spec.Staging` for the keys and the variables they set. An `:env`
  entry that `:s3` would also set is an error naming that variable.

  ## Building the container environment

  A provider translator calls `container_env/1`. It returns `:env`, the
  callback variables and the staging variables in one map, so no provider can
  forget one of them.

  `new/1` holds each `:env` value as an `ExAtlas.Secret`, since any of them can
  be a token. `container_env/1` returns the values themselves.
  """

  alias ExAtlas.{Callback, Secret}
  alias ExAtlas.Spec.Staging

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
            s3: nil,
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
          env: %{optional(String.t()) => Secret.t()},
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
          s3: Staging.t() | nil,
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
    # Checked by `validate_env/1`: NimbleOptions puts the env in its error.
    env: [type: :any, default: %{}],
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
    # Checked by `Staging.new/1`: NimbleOptions puts the input in its error.
    s3: [type: :any, default: nil],
    provider_opts: [type: :map, default: %{}]
  ]

  @doc "Build a validated `ComputeRequest` from keyword opts. Raises on invalid input."
  @spec new!(keyword() | map()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, request} -> request
      {:error, error} -> raise error
    end
  end

  @doc """
  Build a validated `ComputeRequest` from keyword opts.

  An error about `:env` or `:s3` names the key at fault and never holds a value.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, NimbleOptions.ValidationError.t()}
  def new(opts) do
    with {:ok, opts} <- normalize(opts),
         {:ok, opts} <- NimbleOptions.validate(opts, @schema),
         :ok <- validate_env(opts[:env]),
         {:ok, staging} <- Staging.new(opts[:s3]),
         :ok <- check_env_overlap(opts[:env], staging) do
      opts = opts |> Keyword.put(:s3, staging) |> Keyword.update!(:env, &seal_env/1)
      {:ok, struct!(__MODULE__, opts)}
    end
  end

  @doc """
  The container environment for `request`: `:env`, then the callback
  variables, then the staging variables, as strings.

  A callback variable replaces an `:env` entry of the same name. `new/1` refuses
  an `:env` entry that the staging also sets.
  """
  @spec container_env(t()) :: %{String.t() => String.t()}
  def container_env(%__MODULE__{} = request) do
    request.env
    |> Map.new(fn {name, value} -> {name, Secret.reveal(value)} end)
    |> Map.merge(callback_env(request.callback))
    |> Map.merge(Staging.env(request.s3))
    |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp callback_env(nil), do: %{}
  defp callback_env(%{} = callback), do: Callback.env(callback)

  defp check_env_overlap(env, staging) do
    case staging |> Staging.env() |> Map.keys() |> Enum.filter(&Map.has_key?(env, &1)) do
      [] ->
        :ok

      names ->
        {:error,
         %NimbleOptions.ValidationError{
           key: :s3,
           value: nil,
           message:
             "invalid value for :s3 option: :env already sets #{Enum.join(Enum.sort(names), ", ")}, " <>
               "which :s3 also sets; set each variable in one place"
         }}
    end
  end

  # Every value can hold a token, and the request lives in frames a crash
  # prints. Names stay readable.
  defp seal_env(env), do: Map.new(env, fn {name, value} -> {name, Secret.wrap(value)} end)

  defp validate_env(env) when is_map(env) and not is_struct(env) do
    case Enum.find(env, fn {name, value} ->
           not (is_binary(name) and is_binary(Secret.reveal(value)))
         end) do
      nil ->
        :ok

      {name, _value} when is_binary(name) ->
        env_error("the value of #{inspect(name)} is not a string")

      _not_a_string_name ->
        env_error("every name must be a string")
    end
  end

  defp validate_env(_env), do: env_error("expected a map")

  defp env_error(detail) do
    {:error,
     %NimbleOptions.ValidationError{
       key: :env,
       value: nil,
       message:
         "invalid value for :env option: expected a map of string names to string values; " <>
           detail
     }}
  end

  # NimbleOptions raises on a non-keyword list with the offending pair, values
  # included, in its message; a function clause error carries the argument.
  defp normalize(opts) when is_map(opts) and not is_struct(opts), do: normalize(Map.to_list(opts))

  defp normalize(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: shape_error()
  end

  defp normalize(_opts), do: shape_error()

  defp shape_error do
    {:error,
     %NimbleOptions.ValidationError{
       key: nil,
       value: nil,
       message: "expected a keyword list or a map with atom keys"
     }}
  end
end
