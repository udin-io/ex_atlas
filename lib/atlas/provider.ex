defmodule Atlas.Provider do
  @moduledoc """
  Behaviour every compute provider must implement.

  A "provider" is any module that can spawn, control, and terminate GPU (or
  CPU) compute resources on some cloud. Atlas ships a full RunPod implementation
  and stubs for Fly.io Machines, Lambda Labs, and Vast.ai. Users can supply
  their own module — the top-level `Atlas` API accepts any module name as a
  `:provider` value, so in-house clouds or test doubles plug in without a PR.

  ## Contract summary

  All callbacks receive a `ctx` — a map holding the API key and any per-call
  overrides resolved by `Atlas.Config`. Callbacks return either a normalized
  struct (`Atlas.Spec.Compute`, `Atlas.Spec.Job`, ...) or a tagged error tuple
  shaped by `Atlas.Error`.

  ## Capabilities

  Not every provider supports every operation. `c:capabilities/0` returns the
  list of atoms the provider honors (e.g. `:serverless`, `:spot`, `:http_proxy`).
  Callers that depend on an optional feature should check capabilities first
  rather than catching `{:error, %Atlas.Error{kind: :unsupported}}`.

  ## Writing your own provider

      defmodule MyCloud.Provider do
        @behaviour Atlas.Provider

        @impl true
        def spawn_compute(%Atlas.Spec.ComputeRequest{} = req, ctx) do
          # translate `req` into MyCloud's native payload and POST it
        end

        @impl true
        def capabilities, do: [:http_proxy]

        # ... all other callbacks ...
      end

      # Use it
      Atlas.spawn_compute([provider: MyCloud.Provider, gpu: :a100_80g, ...])
  """

  alias Atlas.Spec

  @type ctx :: %{
          required(:api_key) => String.t() | nil,
          required(:provider) => atom(),
          optional(:base_url) => String.t(),
          optional(:req_options) => keyword(),
          optional(atom()) => term()
        }

  @type id :: String.t()
  @type result(t) :: {:ok, t} | {:error, Atlas.Error.t() | term()}

  @doc "Provision a compute resource from a normalized `ComputeRequest`."
  @callback spawn_compute(Spec.ComputeRequest.t(), ctx) :: result(Spec.Compute.t())

  @doc "Fetch the current state of a resource by provider id."
  @callback get_compute(id, ctx) :: result(Spec.Compute.t())

  @doc "List resources; providers should honor at minimum `:status` and `:name` filters."
  @callback list_compute(keyword(), ctx) :: result([Spec.Compute.t()])

  @doc "Stop a resource without destroying its storage (resume-able)."
  @callback stop(id, ctx) :: :ok | {:error, term()}

  @doc "Resume a previously stopped resource."
  @callback start(id, ctx) :: :ok | {:error, term()}

  @doc "Destroy a resource and its ephemeral storage."
  @callback terminate(id, ctx) :: :ok | {:error, term()}

  @doc "Submit a serverless job. Returns `{:error, :unsupported}` if the provider has no serverless."
  @callback run_job(Spec.JobRequest.t(), ctx) :: result(Spec.Job.t())

  @doc "Fetch a job's status by id."
  @callback get_job(id, ctx) :: result(Spec.Job.t())

  @doc "Cancel an in-flight job."
  @callback cancel_job(id, ctx) :: :ok | {:error, term()}

  @doc "Stream intermediate outputs for a job. Returns a lazy `Enumerable`."
  @callback stream_job(id, ctx) :: Enumerable.t()

  @doc """
  List the capabilities the provider honors. Examples:

    * `:spot` — can rent interruptible instances
    * `:serverless` — supports `run_job/2`
    * `:network_volumes` — can attach persistent storage
    * `:http_proxy` — auto-terminated HTTPS proxy per pod
    * `:raw_tcp` — public IP + mapped TCP ports
    * `:symmetric_ports` — inside-port == outside-port guarantee
    * `:webhooks` — push completion callbacks
    * `:global_networking` — private networking across datacenters
  """
  @callback capabilities() :: [atom()]

  @doc "Return the provider's catalog of GPU types and current prices."
  @callback list_gpu_types(ctx) :: result([Spec.GpuType.t()])

  @optional_callbacks [
    list_gpu_types: 1,
    run_job: 2,
    get_job: 2,
    cancel_job: 2,
    stream_job: 2
  ]
end
