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
  filesystems") keeps its records in its own database with
  `ExAtlas.Orchestrator.TrackingStore.Ecto`, or implements this behaviour
  against whatever else it trusts to survive a deploy:

      config :ex_atlas, :orchestrator, tracking_store: MyApp.AtlasStore

  A store that needs a process the host starts (a repo, a Redis client) is
  read at boot by the Adopter, so the orchestrator must start after it: set
  `start_orchestrator: false` and put `ExAtlas.Orchestrator.Supervisor` in the
  host's children after that process.

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
    * `:owner` — the spawning node's `:reap_owner`, or `nil` when it had none.
      Version 1 records carry no owner.
    * `:id`, `:provider` — what to re-observe, and where.
    * `:opts` — **scrubbed** spawn opts. `ComputeServer` re-validates them and
      `ExAtlas.terminate/2` needs them. Keep `opts[:callback]` whole, its
      `:attempt` included: a descriptor without an integer `:attempt` reads as
      a pod rented by 0.8.0, whose token signs none, and the adopted task
      refuses the current pod's reports once a respawn gave it one.
    * `:spawned_at_ms` — `System.system_time(:millisecond)`, wall clock. The
      tracker's own `deadline_at_ms` is `System.monotonic_time/1`, which means
      nothing across a VM restart; this is the anchor that lets a carried
      deadline exist at all.
    * `:max_runtime_ms`, `:respawns` — budgets that must not refill. A
      restarted 90-minute task gets what is *left* of 90 minutes, and a
      `{:respawn, n}` budget already spent stays spent.
    * `:respawning` — the attempt a respawn started and has not finished, or
      `nil`. The respawn writes it before it rents the replacement, so a node
      that dies before the record moves to the replacement leaves this mark.
      The next boot then counts that attempt as spent and refuses its token:
      the replacement it rented is an orphan no tracker holds. A record
      without the field, as 0.8.0 wrote it, reads as `nil`. Keep it: a store
      that drops it adopts that task as if no respawn had started, and the
      orphan's reports pass once the task respawns again.
    * `:callback_task_id` — so `{:callback, task_id}` is re-registered and
      in-flight pod callbacks stop answering `410 Gone`. Not a secret:
      `ExAtlas.Callback.Token` is stateless (`Plug.Crypto.sign/3`), carries its
      own `max_age`, and verifies on any node.
    * `:report` — a `finish` that landed before the restart, so the "never
      respawn something that already reported" rule survives too.
    * `:mode`, `:user_id` — the task/interactive branch, and host-side
      ownership.
    * `:max_cost`, `:spent_usd`, `:cost_rate`, `:cost_since_ms` — the cost
      cap and its meter, so a restart does not refill the budget either.
      `:spent_usd` is the spend of closed segments; the open segment runs at
      `:cost_rate` dollars per hour from `:cost_since_ms`, wall clock like
      `:spawned_at_ms`. An uncapped record holds `false`, `0.0`, `nil`, `nil`.
      Version 1 and 2 records carry none of them and read as uncapped.

  Never stored: `compute.auth.token` (the raw preshared key — see
  `ExAtlas.Auth.Token`), `:api_key` (re-resolved from config at adoption,
  exactly as a fresh spawn does), `:base_url` and `:req_options` (read from
  `config :ex_atlas, <provider>` at adoption, see "Where an adopted task's
  calls go"), the keys and presigned URLs of `:s3`, the
  values of `:env`, and anything else matching `:scrub_keys`. `:s3` keeps its endpoint, region and
  URIs beside `credentials: :not_stored`, so an adopted task with `s3:` runs
  on, and its respawn asks the `respawn_credentials:` resolver for the
  credentials, or fails without one. `last_activity_ms` is not stored because it is monotonic and
  nobody was touching the session while the node was down.

  ### Container environment: names only

  Any `:env` value can be a token, so a record keeps the names alone, each with
  the value `:not_stored`. An adopted task runs on, and a respawn after
  adoption asks the `respawn_credentials:` resolver for the values. With no
  resolver it broadcasts `{:respawn_failed, {reason, %ExAtlas.Error{kind:
  :validation}}}` and ends the task. An empty `:env` is stored as `%{}` and
  respawns as before.

  ### The resolver tuple

  `opts[:respawn_credentials]` is an `{module, function, args}` and is stored
  as given. Keep it whole: a store that drops it, or turns its atoms into
  strings, adopts the task without it, logs a warning, and the respawn falls
  back to `config :ex_atlas, :orchestrator, respawn_credentials:`. Its args
  are written to the store, so they must hold no secret. With
  `scrub_keys: [:env]` the record holds `env: :not_stored`, which refuses the
  same respawn.

  A record written before this rule holds the values: its adopted tracker
  seals them, and its respawn still sends them. Every rewrite of the record
  (a claim, a cost update, a respawn) stores the names alone, so the values
  serve one adoption and no more.

  A host store that returns the marker as the string `"not_stored"` refuses
  the respawn the same way. A host store that drops `:env` from the opts
  leaves nothing to refuse on, and its adopted respawn runs with no
  environment.

  ## Where an adopted task's calls go

  Whoever can write the store writes the record the next boot adopts, and the
  adopted task calls its provider with this node's API key. So the record
  steers neither where those calls go nor which code makes them:

    * `:api_key`, `:base_url` and `:req_options` come from
      `config :ex_atlas, <provider>`, never from the record: a stored key
      would point every call at the writer's own account. A record does not store them; one written before this
      rule keeps them, the adopted task ignores them, and the first rewrite of
      the record drops them. A host that passes either per call to a
      `persist: true` spawn sets them in config too, or its adopted tasks call
      the provider's public URL.
    * The provider is adopted only when it is a built-in name or a module
      that declares `@behaviour ExAtlas.Provider`. Any other record is
      skipped, kept, and logged.

  The record still chooses what a respawn after adoption rents (the image,
  command, GPU and env names) and the callback descriptor its token is minted
  over. With `respawn_credentials:`, the resolver's secrets go into that
  image. A writer needs a live pod of this account that then fails for it to
  come to that (issue 131).

  ## A store shared by several nodes

  A node adopts only the records whose `:owner` is its own `:reap_owner`. Set
  `:reap_owner` on every node that shares a store (see
  `ExAtlas.Orchestrator.Reaper`), and keep it stable across restarts.

    * A record of another owner stays in the store, untracked on this node, and
      the boot logs its id under that owner. No node deletes it.
    * A record with no owner (version 1, or written by a node with no
      `:reap_owner`) is claimed by the first node that adopts it, which writes
      its own owner into it.
    * A dead owner's pods and records stay until an operator deletes them. "Node
      A died, node B takes over" needs leases with expiry and is not solved
      here.

  A store that maps record fields to columns needs a nullable `owner` column.
  Without it every record comes back unowned, and every node adopts it. It
  needs the four cost columns too, `cost_rate` and `cost_since_ms` nullable:
  without them an adopted task's budget refills. And a nullable integer
  `respawning`: without it, a pod rented by a respawn the node died in keeps a
  token the next boot accepts.

  A per-node DETS file (the default) holds only that node's records, so it
  needs none of this.

  ## Fly and other ephemeral filesystems

  A Fly machine **with no attached volume gets a fresh filesystem on every
  deploy**. Both `priv` and `tmp` are ephemeral there, so the DETS default
  comes up empty at boot: adoption silently does nothing and the Reaper — which
  cannot tell an unrecorded pod of ours from someone else's — reaps the pods
  anyway. Mount a volume and point `:storage_path` at it, or keep the records
  in the host's database with `ExAtlas.Orchestrator.TrackingStore.Ecto`.

  ## When the store cannot account for itself

  If `all/0` returns `{:error, _}` — a corrupt DETS file that had to be
  recreated, a database that will not answer — the Adopter adopts nothing and
  **disables reaping for the entire boot**. Unlike Fly's cached tokens this
  state is not re-acquirable, and a node that cannot tell which pods are its
  own must never issue a DELETE. The cost is bounded by `:max_runtime_ms` plus
  an operator reading the warning; the alternative is destroying live work.
  """

  alias ExAtlas.Orchestrator.{CostMeter, Ownership}
  alias ExAtlas.Spec

  @typedoc "Schema version of a persisted record."
  @type version :: pos_integer()

  @typedoc """
  Everything needed to rebuild a tracker for a resource this node spawned.
  """
  @type record :: %{
          required(:v) => version(),
          required(:owner) => String.t() | nil,
          required(:id) => String.t(),
          required(:provider) => atom() | module(),
          required(:opts) => keyword(),
          required(:spawned_at_ms) => integer(),
          required(:max_runtime_ms) => pos_integer() | false,
          required(:respawns) => non_neg_integer(),
          optional(:respawning) => pos_integer() | nil,
          required(:callback_task_id) => String.t() | nil,
          required(:report) => map() | nil,
          required(:mode) => :interactive | :task,
          required(:user_id) => term(),
          required(:max_cost) => number() | false,
          required(:spent_usd) => float(),
          required(:cost_rate) => float() | nil,
          required(:cost_since_ms) => integer() | nil
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
  @version 3

  # What a record older than `@version` lacks. Version 1 had no owner; neither
  # 1 nor 2 could carry a cost cap, since `persist: true` refused `max_cost`.
  @upgrade_defaults %{
    owner: nil,
    max_cost: false,
    spent_usd: 0.0,
    cost_rate: nil,
    cost_since_ms: nil
  }

  # Opts that are credentials, or that could carry one. `:s3` gets its own
  # treatment below because the secret is nested inside.
  @secret_opts [:api_key, :api_secret, :secret, :token, :password]

  # Opts that say where a provider call goes and how it is sent. Whoever can
  # write the store could point them, with this node's key, at any host, so an
  # adopted task reads them from app config, as it reads `:api_key`.
  @endpoint_opts [:base_url, :req_options]

  # What an adopted record's opts never supply. A stored key would point every
  # call, and a respawn's rent, at the writer's own account.
  @ignored_opts @secret_opts ++ @endpoint_opts

  @doc "The current record schema version."
  @spec version() :: version()
  def version, do: @version

  @doc "Whether this build can read a record of schema version `v`."
  @spec readable?(term()) :: boolean()
  def readable?(v), do: v in 1..@version//1

  @doc """
  A readable record of an older version, as a current one.

  Fills the fields the older version lacks with the values that version
  implied, and leaves a current record as it is.
  """
  @spec upgrade(map()) :: record()
  def upgrade(%{v: @version} = record), do: record
  def upgrade(record), do: @upgrade_defaults |> Map.merge(record) |> Map.put(:v, @version)

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
      owner: owner(),
      id: compute.id,
      provider: Keyword.get(opts, :provider, compute.provider),
      opts: scrub_opts(opts),
      spawned_at_ms: System.system_time(:millisecond),
      max_runtime_ms: Keyword.get(tracking, :max_runtime_ms, false),
      respawns: 0,
      respawning: nil,
      callback_task_id: callback_task_id(Keyword.get(tracking, :callback)),
      report: nil,
      mode: Keyword.get(tracking, :mode, :interactive),
      user_id: Keyword.get(tracking, :user_id)
    }
    |> Map.merge(initial_cost(Keyword.get(tracking, :max_cost, false), compute))
  end

  defp initial_cost(false, _compute),
    do: %{max_cost: false, spent_usd: 0.0, cost_rate: nil, cost_since_ms: nil}

  defp initial_cost(max_cost, compute) do
    now = System.system_time(:millisecond)
    meter = CostMeter.new(max_cost, compute.cost_per_hour, now)
    Map.put(cost_fields(meter, now), :max_cost, max_cost)
  end

  @doc """
  The record fields for `meter`, whose open segment began at wall-clock
  `since_ms`.
  """
  @spec cost_fields(CostMeter.t(), integer()) :: map()
  def cost_fields(%CostMeter{} = meter, since_ms) do
    %{spent_usd: meter.spent_before, cost_rate: meter.rate, cost_since_ms: since_ms}
  end

  @doc """
  Remove credentials from a spawn keyword list before it reaches disk.

  Drops `#{inspect(@secret_opts)}`, anything named by
  `config :ex_atlas, :orchestrator, scrub_keys: [...]`, and
  `#{inspect(@endpoint_opts)}`: an adopted task takes those from
  `config :ex_atlas, <provider>`. `:s3` keeps
  its endpoint, region and URIs, and `credentials: :not_stored` in place of
  the keys and presigned URLs (`ExAtlas.Spec.Staging.scrub/1`); with
  `scrub_keys: [:s3]` it keeps the marker alone. `:env` keeps its names, each
  with the value `:not_stored`; with `scrub_keys: [:env]` it is `:not_stored`
  alone. An empty `:env` stays `%{}`.
  """
  @spec scrub_opts(keyword()) :: keyword()
  def scrub_opts(opts) do
    scrub_keys = configured_scrub_keys()

    opts
    |> Keyword.drop(@secret_opts ++ @endpoint_opts ++ scrub_keys)
    |> put_staging(Keyword.get(opts, :s3), :s3 in scrub_keys)
    |> put_env(Keyword.get(opts, :env), :env in scrub_keys)
  end

  @doc """
  `record` with its `:env` values, its credentials, `:base_url` and
  `:req_options` left out, as `scrub_opts/1` leaves them.

  A record written before these rules, or by someone other than this app, can
  hold them; every rewrite of it goes through here, so no write lays them
  down again.
  """
  @spec scrub_record(record()) :: record()
  def scrub_record(%{opts: opts} = record) do
    opts = Keyword.drop(opts, @ignored_opts)
    %{record | opts: put_env(opts, Keyword.get(opts, :env), :env in configured_scrub_keys())}
  end

  @doc """
  The opts an adopted record is observed and tracked with.

  The provider comes back from the record. `:api_key`, `:base_url` and
  `:req_options` come from application config, exactly as a fresh spawn
  without them resolves them. `scrub_opts/1` never stores them, so a record
  that holds one was written before that rule or by someone else, who chose
  it: a stored key would point every call at the writer's own account.
  """
  @spec observe_opts(record()) :: keyword()
  def observe_opts(record) do
    record.opts
    |> Keyword.drop(@ignored_opts)
    |> Keyword.put_new(:provider, record.provider)
  end

  @doc """
  The `#{inspect(@ignored_opts)}` keys `record` holds a value for, which
  `observe_opts/1` leaves out.
  """
  @spec ignored_opts(record()) :: [atom()]
  def ignored_opts(%{opts: opts}),
    do: Enum.filter(@ignored_opts, &(Keyword.get(opts, &1) != nil))

  # `scrub_keys: [:s3]` keeps the marker alone, never nothing: a record with no
  # `s3:` would let an adopted task respawn with no staging at all.
  defp put_staging(opts, nil, _scrubbed?), do: opts
  defp put_staging(opts, _s3, true), do: Keyword.put(opts, :s3, Spec.Staging.scrub(nil))
  defp put_staging(opts, s3, false), do: Keyword.put(opts, :s3, Spec.Staging.scrub(s3))

  # Any env value can be a token, so none reaches the store. The names stay,
  # so an operator reading a record sees what an adopted respawn would lack.
  # The marker survives `scrub_keys: [:env]`, as `s3:`'s does: a record with no
  # `env:` would respawn a pod with no environment at all.
  defp put_env(opts, nil, _scrubbed?), do: opts
  defp put_env(opts, env, _scrubbed?) when env == %{}, do: Keyword.put(opts, :env, %{})

  defp put_env(opts, env, false) when is_map(env),
    do: Keyword.put(opts, :env, Map.new(env, fn {name, _value} -> {name, :not_stored} end))

  defp put_env(opts, _env, _scrubbed?), do: Keyword.put(opts, :env, :not_stored)

  defp configured_scrub_keys do
    orchestrator_config() |> Keyword.get(:scrub_keys, []) |> List.wrap()
  end

  # `ExAtlas.Orchestrator.spawn/1` has already validated `:reap_owner`.
  defp owner do
    case Ownership.owner() do
      {:ok, owner} -> owner
      {:error, _invalid} -> nil
    end
  end

  defp callback_task_id(%{task_id: task_id}), do: task_id
  defp callback_task_id(_no_callback), do: nil

  defp orchestrator_config, do: Application.get_env(:ex_atlas, :orchestrator, [])
end
