defmodule ExAtlas.Orchestrator.TrackingStore do
  @moduledoc """
  Behaviour for durable tracking of the compute this node spawned.

  Everything else in the orchestrator is in-memory: `ComputeRegistry` is a
  plain `Registry` and `ExAtlas.Orchestrator.ComputeServer` is
  `restart: :temporary`. That is correct for a crash — a dead tracker has
  already deleted its resource — and wrong for a **deploy**, which empties the
  registry while the pods keep running. `ExAtlas.Orchestrator.Reaper` then sees
  a live, prefix-matching, hours-old pod with no tracker and DELETEs it, which
  for a task is hours of GPU spend destroyed.

  A `TrackingStore` is the one piece of state that survives the VM, so
  `ExAtlas.Orchestrator.Adopter` can re-create trackers at boot and the Reaper
  can tell "someone else's pod" from "ours, not adopted yet".

  ## The behaviour is the point

  The DETS default is a zero-config convenience, not the recommendation. A host
  that runs on ephemeral filesystems (see "Fly and other ephemeral
  filesystems") should implement this behaviour against whatever it already
  trusts to survive a deploy:

      config :ex_atlas, :orchestrator, tracking_store: MyApp.AtlasStore

  Five callbacks, no lifecycle to get right beyond `child_spec/1`:

      @behaviour ExAtlas.Orchestrator.TrackingStore

      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
      def put(record),      do: MyApp.Repo.insert!(...) && :ok
      def get(id),          do: ...   # {:ok, record} | :error
      def delete(id),       do: ...   # :ok
      def all,              do: ...   # {:ok, [record]} | {:error, term}

  `test/support`'s `ExAtlas.Orchestrator.TrackingStoreConformance` is a shared
  ExUnit suite your implementation can `use` to inherit the contract tests.

  Set `tracking_store: false` to disable persistence entirely; the orchestrator
  then behaves exactly as it did before this feature existed.

  ## Persistence is opt-in per spawn

  A store being configured persists nothing on its own. Each spawn opts in:

      ExAtlas.Orchestrator.run_task(
        provider: :runpod,
        gpu: :h100,
        image: "ghcr.io/acme/trainer:latest",
        command: ["/app/train.sh"],
        name: "atlas-train-\#{run.id}",
        max_runtime_ms: :timer.hours(6),
        persist: true
      )

  `persist: false` is the default and is byte-identical to the old behaviour.

  ## Tasks only

  `persist: true` requires `mode: :task`. An interactive session's
  `compute.auth.token` is a bearer credential `ExAtlas.Auth.Token` promises is
  never written down, so an adopted session would come back with `auth: nil` —
  a pod nobody can authenticate to, billing for another full idle TTL, for a
  user whose browser is long gone. `ExAtlas.Orchestrator.spawn/1` rejects the
  combination rather than silently persisting something it cannot restore.

  ## What is stored, and what is deliberately not

  `t:record/0` holds exactly what it takes to rebuild a tracker:

    * `:v` — record schema version. An unknown version is dropped with a
      warning rather than guessed at.
    * `:id`, `:provider` — what to re-observe, and where.
    * `:opts` — **scrubbed** spawn opts. `ComputeServer` re-validates them and
      `ExAtlas.terminate/2` needs them.
    * `:spawned_at_ms` — `System.system_time(:millisecond)`, wall clock. The
      tracker's own `deadline_at_ms` is `System.monotonic_time/1`, which means
      nothing across a VM restart; this is the anchor that lets a carried
      deadline exist at all.
    * `:max_runtime_ms`, `:respawns` — budgets that must not refill. A
      restarted 90-minute task gets what is *left* of 90 minutes, and a
      `{:respawn, n}` budget already spent stays spent.
    * `:callback_task_id` — so `{:callback, task_id}` is re-registered and
      in-flight pod callbacks stop answering `410 Gone`. Not a secret:
      `ExAtlas.Callback.Token` is stateless (`Plug.Crypto.sign/3`), carries its
      own `max_age`, and verifies on any node.
    * `:report` — a `finish` that landed before the restart, so the "never
      respawn something that already reported" rule survives too.
    * `:mode`, `:user_id` — the task/interactive branch, and host-side
      ownership.

  Never stored: `compute.auth.token` (the raw preshared key — see
  `ExAtlas.Auth.Token`), `:api_key` (re-resolved from config at adoption,
  exactly as a fresh spawn does), and anything else matching
  `:scrub_keys`. `last_activity_ms` is not stored because it is monotonic and
  nobody was touching the session while the node was down.

  ### Container environment is *not* scrubbed

  `:env` is persisted verbatim, because a respawn after adoption without it
  would silently run broken work. If you inject secrets into containers through
  `:env`, either extend the scrub list —

      config :ex_atlas, :orchestrator, scrub_keys: [:env]

  — and accept that respawn-after-adoption loses them, or supply a store that
  encrypts at rest.

  ## Single node, by design

  A node adopts only ids it wrote itself, which a per-node DETS file makes
  automatic. "Node A died, node B takes over its pods" is explicitly **not**
  solved here: it needs a shared store plus leases with an owner column and
  expiry, which is a different ticket. Note also that the Reaper is already
  unsafe on 2+ nodes sharing one provider account and `:reap_name_prefix`
  (issue #38) — this feature does not change that either way. Run one
  orchestrating node, or give each node its own `:reap_name_prefix`.

  ## Fly and other ephemeral filesystems

  A Fly machine **with no attached volume gets a fresh filesystem on every
  deploy**. Both `priv` and `tmp` are ephemeral there, so the DETS default
  comes up empty at boot: adoption silently does nothing and the Reaper — which
  cannot tell an unrecorded pod of ours from someone else's — reaps the pods
  anyway. Mount a volume and point `:storage_path` at it, or supply a store
  backed by something already durable.

  ## When the store cannot account for itself

  If `all/0` returns `{:error, _}` — a corrupt DETS file that had to be
  recreated, a database that will not answer — the Adopter adopts nothing and
  **disables reaping for the entire boot**. Unlike Fly's cached tokens this
  state is not re-acquirable, and a node that cannot tell which pods are its
  own must never issue a DELETE. The cost is bounded by `:max_runtime_ms` plus
  an operator reading the warning; the alternative is destroying live work.
  """

  alias ExAtlas.Spec

  @typedoc "Schema version of a persisted record."
  @type version :: pos_integer()

  @typedoc """
  Everything needed to rebuild a tracker for a resource this node spawned.
  """
  @type record :: %{
          required(:v) => version(),
          required(:id) => String.t(),
          required(:provider) => atom() | module(),
          required(:opts) => keyword(),
          required(:spawned_at_ms) => integer(),
          required(:max_runtime_ms) => pos_integer() | false,
          required(:respawns) => non_neg_integer(),
          required(:callback_task_id) => String.t() | nil,
          required(:report) => map() | nil,
          required(:mode) => :interactive | :task,
          required(:user_id) => term()
        }

  @doc "Write `record`, replacing any record with the same `:id`."
  @callback put(record()) :: :ok

  @doc "Fetch the record for `id`."
  @callback get(String.t()) :: {:ok, record()} | :error

  @doc "Remove the record for `id`. A no-op when there is none."
  @callback delete(String.t()) :: :ok

  @doc """
  Every stored record.

  `{:error, reason}` means "I cannot account for my contents" — the caller
  must then neither adopt nor reap. It is not the same as `{:ok, []}`.
  """
  @callback all() :: {:ok, [record()]} | {:error, term()}

  @callback child_spec(keyword()) :: Supervisor.child_spec()

  # Bumped whenever a field is added, removed, or reinterpreted. A record whose
  # version this build does not know is dropped rather than guessed at: a
  # half-understood record could arm the wrong deadline on a live GPU.
  @version 1

  # Opts that are credentials, or that could carry one. `:req_options` gets its
  # own treatment below because the secret is nested inside it.
  @secret_opts [:api_key, :api_secret, :secret, :token, :password]

  @doc "The current record schema version."
  @spec version() :: version()
  def version, do: @version

  @doc """
  The configured implementation, or `nil` when persistence is disabled.

      config :ex_atlas, :orchestrator, tracking_store: MyApp.AtlasStore  # or false
  """
  @spec impl() :: module() | nil
  def impl do
    case Keyword.get(orchestrator_config(), :tracking_store, __MODULE__.Dets) do
      false -> nil
      nil -> nil
      module when is_atom(module) -> module
    end
  end

  @doc """
  Build a record for a freshly spawned resource.

  `tracking` is the validated tracking keyword list from
  `ExAtlas.Orchestrator.ComputeServer.validate_opts/1`; `opts` is the full,
  unscrubbed spawn keyword list.
  """
  @spec new(Spec.Compute.t(), keyword(), keyword()) :: record()
  def new(%Spec.Compute{} = compute, opts, tracking) do
    %{
      v: @version,
      id: compute.id,
      provider: Keyword.get(opts, :provider, compute.provider),
      opts: scrub_opts(opts),
      spawned_at_ms: System.system_time(:millisecond),
      max_runtime_ms: Keyword.get(tracking, :max_runtime_ms, false),
      respawns: 0,
      callback_task_id: callback_task_id(Keyword.get(tracking, :callback)),
      report: nil,
      mode: Keyword.get(tracking, :mode, :interactive),
      user_id: Keyword.get(tracking, :user_id)
    }
  end

  @doc """
  Remove credentials from a spawn keyword list before it reaches disk.

  Drops `#{inspect(@secret_opts)}`, anything named by
  `config :ex_atlas, :orchestrator, scrub_keys: [...]`, and the `:auth` /
  `:headers` entries of `:req_options`, which is where a hand-rolled bearer
  header would be.
  """
  @spec scrub_opts(keyword()) :: keyword()
  def scrub_opts(opts) do
    opts
    |> Keyword.drop(@secret_opts ++ configured_scrub_keys())
    |> scrub_req_options()
  end

  @doc """
  The opts to re-observe an adopted record with.

  The provider comes back from the record — `:api_key` was scrubbed, so it is
  re-resolved from application config, exactly as a fresh spawn resolves it.
  """
  @spec observe_opts(record()) :: keyword()
  def observe_opts(record), do: Keyword.put_new(record.opts, :provider, record.provider)

  defp scrub_req_options(opts) do
    case Keyword.fetch(opts, :req_options) do
      {:ok, req_options} when is_list(req_options) ->
        Keyword.put(opts, :req_options, Keyword.drop(req_options, [:auth, :headers]))

      _not_a_keyword_list ->
        opts
    end
  end

  defp configured_scrub_keys do
    orchestrator_config() |> Keyword.get(:scrub_keys, []) |> List.wrap()
  end

  defp callback_task_id(%{task_id: task_id}), do: task_id
  defp callback_task_id(_no_callback), do: nil

  defp orchestrator_config, do: Application.get_env(:ex_atlas, :orchestrator, [])
end
