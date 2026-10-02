defmodule ExAtlas.Provider do
  @moduledoc """
  Behaviour every compute provider must implement.

  A "provider" is any module that can spawn, control, and terminate GPU (or
  CPU) compute resources on some cloud. ExAtlas ships a full RunPod implementation,
  a Lambda Labs implementation of the compute callbacks, and stubs for Fly.io
  Machines and Vast.ai. Users can supply
  their own module — the top-level `ExAtlas` API accepts any module name as a
  `:provider` value, so in-house clouds or test doubles plug in without a PR.

  ## Contract summary

  All callbacks receive a `ctx` — a map holding the API key and any per-call
  overrides resolved by `ExAtlas.Config`. Callbacks return either a normalized
  struct (`ExAtlas.Spec.Compute`, `ExAtlas.Spec.Job`, ...) or a tagged error tuple
  shaped by `ExAtlas.Error`.

  `ctx.api_key` is an `ExAtlas.Secret` or `nil`. Call `ExAtlas.Secret.reveal/1`
  only where the HTTP client reads the key: a crash in any frame that holds
  the ctx then prints `#ExAtlas.Secret<redacted>`. The `:auth`, `:headers`
  and `:aws_sigv4` entries of `ctx.req_options` are Secrets too;
  `ExAtlas.Config.reveal_req_options/1` unwraps them.

  ## Capabilities

  Not every provider supports every operation. `c:capabilities/0` returns the
  list of atoms the provider honors (e.g. `:serverless`, `:spot`, `:http_proxy`).
  Callers that depend on an optional feature should check capabilities first
  rather than catching `{:error, %ExAtlas.Error{kind: :unsupported}}`.

  ## Writing your own provider

      defmodule MyCloud.Provider do
        @behaviour ExAtlas.Provider

        @impl true
        def spawn_compute(%ExAtlas.Spec.ComputeRequest{} = req, ctx) do
          # translate `req` into MyCloud's native payload and POST it
        end

        @impl true
        def capabilities, do: [:http_proxy]

        # ... all other callbacks ...
      end

      # Use it
      ExAtlas.spawn_compute([provider: MyCloud.Provider, gpu: :a100_80g, ...])
  """

  alias ExAtlas.Spec

  @type ctx :: %{
          required(:api_key) => ExAtlas.Secret.t() | nil,
          required(:provider) => atom(),
          optional(:base_url) => String.t(),
          optional(:req_options) => keyword(),
          optional(atom()) => term()
        }

  @type id :: String.t()
  @type result(t) :: {:ok, t} | {:error, ExAtlas.Error.t() | term()}

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
    * `:manage_network_volumes` — implements the four network volume callbacks
    * `:manage_templates` — implements the four template callbacks
    * `:manage_endpoints` — implements the three serverless endpoint callbacks
    * `:billing` — implements `compute_spend/3`
    * `:http_proxy` — auto-terminated HTTPS proxy per pod
    * `:raw_tcp` — public IP + mapped TCP ports
    * `:symmetric_ports` — inside-port == outside-port guarantee
    * `:webhooks` — push completion callbacks
    * `:global_networking` — private networking across datacenters
    * `:self_terminate` — honors `ComputeRequest.self_terminate`, wrapping
      `:command` so the resource destroys itself when the command ends
  """
  @callback capabilities() :: [atom()]

  @doc "Return the provider's catalog of GPU types and current prices."
  @callback list_gpu_types(ctx) :: result([Spec.GpuType.t()])

  @doc "List the account's network volumes."
  @callback list_network_volumes(ctx) :: result([Spec.NetworkVolume.t()])

  @doc "Fetch one network volume by id."
  @callback get_network_volume(id, ctx) :: result(Spec.NetworkVolume.t())

  @doc "Create a network volume."
  @callback create_network_volume(Spec.NetworkVolumeRequest.t(), ctx) ::
              result(Spec.NetworkVolume.t())

  @doc "Delete a network volume. Destroys its data."
  @callback delete_network_volume(id, ctx) :: :ok | {:error, term()}

  @doc "List the account's templates."
  @callback list_templates(ctx) :: result([Spec.Template.t()])

  @doc "Fetch one template by id."
  @callback get_template(id, ctx) :: result(Spec.Template.t())

  @doc "Create a template."
  @callback create_template(Spec.TemplateRequest.t(), ctx) :: result(Spec.Template.t())

  @doc "Delete a template."
  @callback delete_template(id, ctx) :: :ok | {:error, term()}

  @doc "List the account's serverless endpoints."
  @callback list_endpoints(ctx) :: result([Spec.Endpoint.t()])

  @doc "Fetch one serverless endpoint by id."
  @callback get_endpoint(id, ctx) :: result(Spec.Endpoint.t())

  @doc "Delete a serverless endpoint."
  @callback delete_endpoint(id, ctx) :: :ok | {:error, term()}

  @doc """
  One compute resource's spend in US dollars.

  `opts` may carry `:from` and `:to` (`DateTime`). With neither, the provider
  covers its own default window, and the returned `Spend` names it.
  """
  @callback compute_spend(id, keyword(), ctx) :: result(Spec.Spend.t())

  @optional_callbacks [
    list_endpoints: 1,
    get_endpoint: 2,
    delete_endpoint: 2,
    compute_spend: 3,
    list_templates: 1,
    get_template: 2,
    create_template: 2,
    delete_template: 2,
    list_network_volumes: 1,
    get_network_volume: 2,
    create_network_volume: 2,
    delete_network_volume: 2,
    list_gpu_types: 1,
    run_job: 2,
    get_job: 2,
    cancel_job: 2,
    stream_job: 2
  ]
end
