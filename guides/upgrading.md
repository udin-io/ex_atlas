# Upgrading

## Upgrading to 0.8.0

Six changes in 0.8.0 break host code or deployments. Find yours in the table,
then read its section.

| Change | Who acts | Section |
|---|---|---|
| `ctx.api_key` and the credentials in `ctx.req_options` are `ExAtlas.Secret` | You wrote a provider module | [Provider modules](#provider-modules-read-secrets-with-reveal) |
| A cluster needs `:reap_owner`, and upgrades in two deploys | You run more than one machine on one account | [Reap owner](#reap-owner-and-the-two-deploy-upgrade) |
| Tracking records v2 carry `owner` | You wrote a `TrackingStore` backed by columns | [Tracking store](#tracking-store-add-an-owner-column) |
| `stop_tracked/1` sends `{:terminating, {:shutdown, :stopped}}`; `terminate_child/2` keeps persisted pods | You match `:shutdown` in a subscriber | [Terminating messages](#terminating-messages) |
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
`@doc false` accessor with no caller in ExAtlas. Call `ExAtlas.Providers.RunPod.Endpoints`
by name, or use the endpoint functions on the public API. See the
[CHANGELOG entry][c59]
(#59).

[c76]: CHANGELOG.md#changed-credentials-travel-as-exatlas-secret-76
[c38]: CHANGELOG.md#fixed-the-reaper-deletes-other-nodes-live-compute-breaking-38
[c46]: CHANGELOG.md#fixed-a-shared-tracking-store-adopts-other-nodes-tasks-breaking-46
[c45]: CHANGELOG.md#fixed-a-graceful-shutdown-deletes-persisted-tasks-45
[c79]: CHANGELOG.md#changed-env-values-print-redacted-and-stay-off-disk-79
[c59]: CHANGELOG.md#removed-the-endpoints_module-function-of-exatlas-providers-runpod-59
