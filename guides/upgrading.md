# Upgrading

## Upgrading to the next release (unreleased)

The Ecto store signs owner lease rows, and a live node now deletes a dead
owner's untracked pods by default.

| Change | Who acts | Section |
|---|---|---|
| `Migration` step 3 adds a `mac` column to `atlas_owner_leases` | You use `TrackingStore.Ecto` and your migrations ran before this release | [Run step 3](#ecto-store-run-step-3) |
| Dead-owner deletion is on by default | You use `TrackingStore.Ecto` and want it off | [Run step 3](#ecto-store-run-step-3) |

`mix igniter.upgrade ex_atlas` prints a notice when a config file sets the
Ecto store. It writes no migration.

### Ecto store: run step 3

Add a migration:

```elixir
defmodule MyApp.Repo.Migrations.SignAtlasOwnerLeases do
  use Ecto.Migration

  def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 3)
  def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down(version: 3)
end
```

Step 3 adds the column only when it is missing, so a fresh database that runs
your install migration (`up/0`, every step) and then this one works.

- Until it runs, each node renews its lease without a signature, logs one
  warning per boot naming `up(version: 3)`, and reads no owner as dead.
  Takeover of a dead owner's records works as before.
- After it runs, each live node signs its row on its next renewal, within
  `lease_ttl_ms / 3`. A row written before that, by a node that died before
  the upgrade, stays unsigned: that owner's untracked pods are logged and
  left, as in 0.9.0. Delete them by hand.
- A node signs and verifies with `config :ex_atlas, :callback, secret:`.
  Nodes with different secrets, or rows written before you rotated the
  secret, read each other's rows as unsigned and never as dead.
- To keep dead-owner deletion off:
  `config :ex_atlas, :orchestrator, reap_dead_owners: false`.
- A 0.9.0 node with `reap_dead_owners: true` still reads unsigned rows as
  dead. Remove that setting from old nodes before you run step 3, or finish
  the rollout first.
- A dead owner's record that no node takes over (unsigned, or from a newer
  release) no longer keeps its pod billing: once the owner reads as dead,
  the Reaper deletes the record, then the pod. A custom tracking store gets
  this only by implementing `delete_expired/3`; without it, those pods stay
  as in 0.9.0.

## Upgrading to 0.9.0

0.9.0 changes what a node adopts after a restart. Five changes need action
from some hosts. Find yours in the table, then read its section.

| Change | Who acts | Section |
|---|---|---|
| An unsigned tracking record cannot respawn, and adopts only a pod the Reaper would delete | You use `persist: true` and set no callback secret | [Callback secret](#set-a-callback-secret) |
| An adopted task takes `base_url:` and `req_options:` from config | You pass either per call to a `persist: true` spawn | [Provider config](#move-per-call-base_url-and-req_options-to-config) |
| A custom provider module needs `@behaviour ExAtlas.Provider` to be adopted | You wrote a provider module | [Provider config](#move-per-call-base_url-and-req_options-to-config) |
| A host store returns each record term for term, with `:respawning` and the callback's `:attempt` | You wrote a `TrackingStore` | [Tracking store](#tracking-store-keep-the-record-whole) |
| `Migration` step 2 creates `atlas_owner_leases` | You ran `TrackingStore.Ecto` from `main` before 0.9.0 | [Ecto store](#ecto-store-from-main-run-step-2) |

Run `mix igniter.upgrade ex_atlas` first. It edits no file. It prints a notice
when your app starts the orchestrator and no config file sets a callback
secret. See `mix help ex_atlas.upgrade`.

### Set a callback secret

A node signs each tracking record it writes with a key derived from
`config :ex_atlas, :callback, secret:`. With no secret, or for a record 0.8.0
wrote, the record is unsigned. After a restart an unsigned record:

- adopts only when this node's Reaper would delete its pod once untracked:
  its provider is in `:reap_providers`, the provider reports it
  `:provisioning` or `:running`, the node has a `:reap_owner` or no connected
  peers, and the pod's name carries `:reap_name_prefix` and the owner;
- never respawns, even with `on_failure: {:respawn, n}`.

A store writer without the secret could otherwise choose what a respawn rents
(#131) or make the node delete any pod of the account (#138). A pod whose
record does not adopt keeps billing, and the Reaper leaves it alone:
terminate it by hand. The log names it ("not adopting ...").

```elixir
# config/runtime.exs
config :ex_atlas, :callback, secret: System.fetch_env!("ATLAS_CALLBACK_SECRET")
```

Rotating the secret makes every stored record unsigned. A `persist: true`
spawn on a node with no secret warns when its task would not adopt. See the
CHANGELOG entries [#131][c131] and [#138][c138].

### Move per-call `base_url:` and `req_options:` to config

A tracking record no longer stores `base_url:`, `req_options:` or `api_key:`.
An adopted task reads all three from `config :ex_atlas, <provider>`, so a
store writer cannot send the node's API key to another host.

Before:

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  persist: true,
  base_url: "https://runpod-proxy.internal",
  # ...
)
```

After:

```elixir
# config/runtime.exs
config :ex_atlas, :runpod, base_url: "https://runpod-proxy.internal"
```

A fresh spawn still uses its per-call values; only a task adopted after a
deploy reads config. The Adopter also adopts a record only when its provider
is built in or a module that declares `@behaviour ExAtlas.Provider`. See the
[CHANGELOG entry][c125] (#125).

### Tracking store: keep the record whole

A custom `TrackingStore` must return each record term for term. Three fields
matter in 0.9.0:

| Field | Without it |
|---|---|
| `:mac`, byte for byte | The record reads as unsigned (see above) |
| `:respawning`, a nullable integer | An orphan of a node that died mid-respawn keeps a valid token (#114) |
| `opts[:callback]` with its `:attempt` | An adopted task refuses its current pod's reports (#110) |

A store that keeps the record as one blob needs nothing. Run the shared
contract against your store; it ships in the package now:

```elixir
use ExAtlas.Orchestrator.TrackingStoreConformance, store: MyApp.AtlasStore
```

The upgrader cannot see your schema, so this step is yours. See the CHANGELOG
entries [#114][c114], [#110][c110] and [#128][c128].

### Ecto store from `main`: run step 2

`TrackingStore.Ecto` is new in 0.9.0. Its migration module runs every step
by default, so a host that installs it with
`mix ex_atlas.install --tracking-store ecto` needs nothing. A host that ran
step 1 from an unreleased `main` adds a migration for the owner leases:

```elixir
defmodule MyApp.Repo.Migrations.AddAtlasOwnerLeases do
  use Ecto.Migration

  def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 2)
  def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down(version: 2)
end
```

Until it runs, the lease logs a warning every tick and takes over no record.
See the
[CHANGELOG entry][c132] (#132).

## Upgrading to 0.8.0

Six changes in 0.8.0 break host code or deployments. Find yours in the table,
then read its section.

| Change | Who acts | Section |
|---|---|---|
| `ctx.api_key` and the credentials in `ctx.req_options` are `ExAtlas.Secret` | You wrote a provider module | [Provider modules](#provider-modules-read-secrets-with-reveal) |
| A cluster needs `:reap_owner`, and upgrades in two deploys | You run more than one machine on one account | [Reap owner](#reap-owner-and-the-two-deploy-upgrade) |
| Tracking records v2 carry `owner` | You wrote a `TrackingStore` backed by columns | [Tracking store](#tracking-store-add-an-owner-column) |
| `stop_tracked/1` sends `{:terminating, {:shutdown, :stopped}}`; `terminate_child/2` keeps persisted pods; interactive deadlines send `{:terminating, _}` | You match `:shutdown`, or `{:task, _}` on an interactive session, in a subscriber | [Terminating messages](#terminating-messages) |
| Records keep `env:` names only | You use `persist: true` with `env:` or `s3:` | [Adopted respawn](#adopted-respawn-needs-respawn_credentials) |
| `RunPod`'s `endpoints_module` function is gone | You call it | [Removed function](#removed-the-endpoints_module-function) |

Run `mix igniter.upgrade ex_atlas` first. It edits no file. It prints a warning
for each module in your project that declares `@behaviour ExAtlas.Provider`,
and a notice when your config starts the orchestrator without a `:reap_owner`.
See `mix help ex_atlas.upgrade`.

### Provider modules read secrets with reveal

`ctx.api_key` is an `ExAtlas.Secret` or `nil`, and so are the `:auth`,
`:headers` and `:aws_sigv4` entries of `ctx.req_options`. A tracker crash used
to print the raw key in its stacktrace; a Secret prints as
`#ExAtlas.Secret<redacted>`. A provider module that passes `ctx.api_key` to an
HTTP client now sends a struct.

Before:

```elixir
defp build_client(ctx) do
  Req.new(
    base_url: "https://api.mycloud.example.com/v1",
    auth: {:bearer, ctx.api_key}
  )
  |> Req.merge(Map.get(ctx, :req_options, []))
end
```

After:

```elixir
defp build_client(ctx) do
  Req.new(
    base_url: "https://api.mycloud.example.com/v1",
    auth: fn -> {:bearer, ExAtlas.Secret.reveal(ctx.api_key)} end
  )
  |> Req.merge(ExAtlas.Config.reveal_req_options(Map.get(ctx, :req_options, [])))
end
```

`ExAtlas.Secret.reveal/1` returns the string. Call it where the HTTP client
reads the key, and nowhere else. Look for the other shapes too:
`%{api_key: key} = ctx`, `Map.get(ctx, :api_key)`, and a `ctx` passed on to a
helper. See [Writing a provider](writing_a_provider.md) and the
[CHANGELOG entry][c76]
(#76, PR #78).

### Reap owner and the two-deploy upgrade

Every node's Reaper used to list the whole provider account and delete each
prefixed pod its own node did not track. Two machines on one account deleted
each other's live pods. 0.8.0 stamps each pod name with the machine's
`:reap_owner`, and the Reaper deletes only its own.

| Deployment | After upgrading |
|---|---|
| One machine, no `:reap_owner` | No change |
| Cluster, no `:reap_owner` | The Reaper stops reaping and logs an error. Leftover pods bill until you set an owner. |
| Cluster, `:reap_owner` set | New pods get stamped names. Pods named by 0.7.0 are left alone. |

Set the owner on every machine, unique per machine and stable across restarts
(1 to 32 characters, `a-z` and `0-9`). On Fly:

```elixir
# config/runtime.exs
config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")
```

A 0.7.0 node beside a 0.8.0 node deletes the new node's pods, so a cluster
upgrades in two deploys:

1. Deploy 0.7.0 with `reap_providers: []`, so no node reaps.
2. Deploy 0.8.0 with `:reap_owner` set and `reap_providers` restored.

See the [CHANGELOG entry][c38]
(#38).

### Tracking store: add an owner column

Tracking records are version 2 and carry `:owner`, the spawning node's
`:reap_owner`. A node adopts only records with its own owner. A store that maps
record fields to columns needs a nullable `owner` column:

```sql
ALTER TABLE atlas_tracking_records ADD COLUMN owner varchar(32) NULL;
```

Use your own table name. Without the column every record reads back unowned,
and every node adopts it, as in 0.7.0. A store that keeps the record as one
blob needs nothing. The upgrader cannot see your schema, so this step is
yours. See the
[CHANGELOG entry][c46]
(#46).

### Terminating messages

`ExAtlas.Orchestrator.stop_tracked/1` ends its tracker with
`{:shutdown, :stopped}`. A subscriber that matched `:shutdown` for it now sees
a tuple.

Before:

```elixir
def handle_info({:terminating, :shutdown}, state), do: ...
```

After:

```elixir
def handle_info({:terminating, {:shutdown, :stopped}}, state), do: ...  # stop_tracked/1
def handle_info({:terminating, :shutdown}, state), do: ...              # node stop
```

A `persist: true` task on a node stop (SIGTERM, `System.stop/0`,
`Application.stop(:ex_atlas)`) keeps its pod and record for the next boot, and
sends `{:terminating, :shutdown}` with no `{:status, :terminated}`.
`DynamicSupervisor.terminate_child/2` on
`ExAtlas.Orchestrator.ComputeSupervisor` now counts as a node stop and keeps a
persisted pod. Use `stop_tracked/1` to end one. On Fly, set
`kill_signal = "SIGTERM"` and a `kill_timeout` of at least 30 seconds. See the
[CHANGELOG entry][c45]
(#45).

An interactive session (`Orchestrator.spawn/1` without `mode: :task`) sends
no `{:task, _}` event any more (#96). Its deadlines announce themselves on
`:terminating`.

Before:

```elixir
def handle_info({:task, :timed_out}, state), do: ...
def handle_info({:task, {:failed, :never_ready}}, state), do: ...
```

After:

```elixir
def handle_info({:terminating, :max_runtime}, state), do: ...
def handle_info({:terminating, :never_ready}, state), do: ...
```

An interactive session with a non-empty `command:`, a `callback:` and
`self_terminate: true` also ends `finish_grace_ms` after its finish report,
with `{:terminating, :finished}`. A `run_task/1` task still sends `{:task, _}`.

### Adopted respawn needs `respawn_credentials:`

A `persist: true` record keeps the names of its `env:` variables and none of
their values, and no `s3:` credentials. An adopted task that the provider
preempts after a restart cannot rent a replacement, so its respawn fails with
`{:respawn_failed, ...}` and the pod is not rented.

Before:

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  persist: true,
  env: %{"HF_TOKEN" => token},
  # ...
)
```

After, add a resolver the respawn calls for fresh values:

```elixir
defmodule MyApp.Atlas do
  @behaviour ExAtlas.Orchestrator.RespawnCredentials

  def credentials(:trainer, info) do
    {:ok, env: %{"HF_TOKEN" => MyApp.Secrets.hf_token()}}
  end
end

ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  persist: true,
  env: %{"HF_TOKEN" => token},
  respawn_credentials: {MyApp.Atlas, :credentials, [:trainer]}
)
```

Or set one resolver for all tasks with
`config :ex_atlas, :orchestrator, respawn_credentials: {m, f, args}`. A task
that never restarted needs none. See the
[CHANGELOG entries][c79]
(#79, #87).

### Removed: the `endpoints_module` function

The `endpoints_module` function of `ExAtlas.Providers.RunPod` was a
`@doc false` accessor with no caller in ExAtlas. Call
`ExAtlas.Providers.RunPod.Endpoints`
by name, or use the endpoint functions on the public API. See the
[CHANGELOG entry][c59]
(#59).

[c76]: CHANGELOG.md#changed-credentials-travel-as-exatlas-secret-76
[c38]: CHANGELOG.md#fixed-the-reaper-deletes-other-nodes-live-compute-breaking-38
[c46]: CHANGELOG.md#fixed-a-shared-tracking-store-adopts-other-nodes-tasks-breaking-46
[c45]: CHANGELOG.md#fixed-a-graceful-shutdown-deletes-persisted-tasks-45
[c79]: CHANGELOG.md#changed-env-values-print-redacted-and-stay-off-disk-79
[c59]: CHANGELOG.md#removed-the-endpoints_module-function-of-exatlas-providers-runpod-59
[c131]: CHANGELOG.md#fixed-an-adopted-task-respawns-only-from-a-record-this-node-signed-131
[c138]: CHANGELOG.md#fixed-a-forged-tracking-record-no-longer-deletes-another-app-s-pod-138
[c125]: CHANGELOG.md#fixed-a-forged-tracking-record-no-longer-steers-an-adopted-task-s-calls-125
[c114]: CHANGELOG.md#fixed-an-orphan-of-a-node-that-died-mid-respawn-gets-410-114
[c110]: CHANGELOG.md#fixed-a-token-with-no-attempt-is-refused-once-a-respawn-replaced-the-pod-110
[c128]: CHANGELOG.md#fixed-the-conformance-suites-ship-in-the-package-128
[c132]: CHANGELOG.md#added-a-live-node-takes-over-a-dead-node-s-tasks-on-the-ecto-store-132
