# Decisions

This page records the choices that still shape ExAtlas, taken from merged PR
bodies and the body of issue #28. It exists so a reader can see what we chose
and what we rejected without reading each PR. PR #70 creates it. Each row
names the PR or issue that holds the reasoning.

## Data staging (feature #26)

| Decision | Alternative not taken | Where |
|---|---|---|
| Option name `s3:` on `ComputeRequest` | `staging:`: more general, but the variables are S3 | #26 |
| `s3:` becomes an `ExAtlas.Spec.Staging` whose `inspect/1` shows only non-secret fields | A plain map: `inspect/1` prints the secret | #26, #75 |
| One `ComputeRequest.container_env/1` (env, callback, staging) that every provider calls | Each translator merges `Staging.env/1` itself: the next provider forgets it | #26, #75 |
| Only `AWS_ENDPOINT_URL_S3`, never the global `AWS_ENDPOINT_URL` | The global one also redirects STS and every other AWS service | #26 |
| Region sets `AWS_REGION` and `AWS_DEFAULT_REGION` | `AWS_REGION` only: aws-cli v1 reads `AWS_DEFAULT_REGION` | #26 |
| An `env:` entry that `s3:` would also set is an error naming it | Either side wins silently | #26, #75 |
| `s3:` and `env:` are validated after NimbleOptions, with messages that name keys, never values | NimbleOptions types: its `ValidationError` holds the input | #26, #75 |
| `inspect(%Spec.Compute{})` hides `raw` | Leave it: RunPod echoes env in `raw` | #26, #75 |
| `persist: true` with `s3:` is refused until #74 | Store `s3:` like `env:`: a credential on disk | #26, #75 |
| URIs must be `s3://bucket/...`; the endpoint `http://` or `https://` | `https://` only: a local MinIO runs on plain HTTP | #26 |
| ExAtlas never presigns and never calls S3 | Presign in ExAtlas: needs a SigV4 signer and host credentials | #26 |

## Cost caps (feature #28)

| Decision | Alternative not taken | Where |
|---|---|---|
| `max_cost` is a tracking option on `Orchestrator.spawn/1` and `run_task/1` | A `ComputeRequest` field: the stateless `spawn_compute/1` would accept it and enforce nothing | #28, #67 |
| Spend is the sum of `cost_per_hour x elapsed` per segment; a poll with a new price starts a segment | Price fixed at spawn: a spot price or a respawn on another host changes it | #28, #67 |
| The cap fires on one computed timer | Check on each heartbeat: no heartbeat in task mode, and up to 60 s late | #28, #67 |
| Elapsed counts from tracker start on the monotonic clock, like `max_runtime_ms` | From `compute.created_at`: a second clock for seconds of difference | #28 |
| Interactive cap: `{:terminating, :cost_cap}`. Task cap: `{:task, {:failed, :cost_cap}}` first | New event or outcome names: `{:failed, reason}` is the shape subscribers already match | #28, #67 |
| A cost cap never respawns; spend carries across a preemption respawn | Fresh budget per pod: "90 minutes must not spend 360" | #28, #67 |
| A provider that returns no price: delete the pod, return `{:error, %ExAtlas.Error{kind: :unsupported}}` | Run uncapped with a warning: a cap nothing enforces | #28, #67 |
| A poll with no price keeps the last known rate | Treat it as 0.0: one bad poll would stop the meter | #28, #67 |
| No default `max_cost` for `run_task/1`; `max_runtime_ms` stays the backstop | A default dollar cap: no value fits one RTX 4090 and eight H100s | #28 |
| A persisted task stores its spend; downtime counts at the last known rate | Skip downtime: the pod billed while the node was down | #28, #69 |
| Reconcile spend = `max(estimate, bill)` for the current pod; a lower bill changes nothing | Replace the estimate with the bill: billing lags by an amount RunPod does not state, so a low bill may be late | #28, #70 |
| Reconcile every 15 min by default when `max_cost` is set; `reconcile_spend_ms: false` turns it off | Off by default: one request per pod per 15 min is cheap, and the bill catches costs the rate misses | #28, #70 |
| `{:error, %ExAtlas.Error{kind: :unsupported}}` from the bill stops reconciling for the session, silently. Other errors broadcast `{:spend_reconcile_failed, error}` | Broadcast every failure: a provider with no billing API would emit one every 15 min, forever | #28, #70 |
| An adopted record's whole stored spend counts as the current pod's. The record never says which pod spent it, so a bill is never added twice | Store the current pod's starting spend in a version 4 record. Rejected: every host store would need a new column, for a case that needs a respawn and a restart both | #70 |
| Every timer option is bounded at 4,294,967,295 ms (`ExAtlas.Orchestrator.Timer`), the longest delay every OTP release accepts | Bound each option at the running OTP release's own limit (about 2^57 ms on OTP 27). Rejected: the limit differs per release, and no task needs 49.7 days | #70 |

## Orchestrator

| Decision | Alternative not taken | Where |
|---|---|---|
| Status poll default 60 s, `false` disables it, separate from `heartbeat_ms` | One clock: user activity and provider tolerance are different pacing | #30 |
| Preemption is inferred: a `spot: true` pod that stops, is terminated or vanishes | Wait for a provider signal: RunPod's API has none | #30 |
| No new process for polling: a timer inside `ComputeServer` | A poller process: it would duplicate teardown logic | #30 |
| Task mode reuses `ComputeServer` with `mode:`; the one mode-dependent decision is the pure `TaskOutcome` | A `TaskServer`: about 400 lines of billing-critical code to copy | #31 |
| No heartbeat in task mode | Keep it: the 30 min idle TTL would kill a 90 min run | #31 |
| `run_task/1` injects self-termination and also sets `max_runtime_ms` | Either alone: they cover disjoint failures | #31 |
| `persist: true` only for `mode: :task` | Interactive too: its auth token is unrecoverable after a restart | #39 |
| The record carries a wall-clock `spawned_at_ms`; the deadline is recomputed on adoption | Persist the monotonic deadline: it means nothing in a new VM | #39 |
| Secrets never reach disk: API keys and auth headers are scrubbed | Store the full opts | #39 |
| The Reaper starts gated; the Adopter releases it. An unreadable store disables reaping for the whole boot | Rely on the first tick being late: luck, not design | #39 |
| Child order is store, Reaper, Adopter | Store, Adopter, Reaper: the Adopter's signal to the Reaper could be lost | #39 |
| An unreachable provider during adoption still gets a tracker | Skip the record: a live pod would have no deadline | #39 |
| "Ours" means in the Registry or in the store | Registry only: a deploy empties it | #39 |
| Each node has a `reap_owner` written into pod names; the Reaper deletes only untracked pods with its own owner. A clustered node with no owner reaps nothing | Document single-node only, or a lease-based shared store | #47 |
| A graceful shutdown keeps `persist: true` tasks for the next boot | Delete on every `:shutdown` (the old behaviour) | #48 |
| Each tracking record stores its `:owner`; a node adopts only its own | Adopt every record in a shared store: two trackers watch one pod | #49 |
| Optional provider callbacks go through `dispatch_optional/3` | Call the module directly: raises on providers without the callback | #60, `CLAUDE.md` |
| `hex.audit` stays in CI and suppresses nothing, even though it fails on cowlib | Ignore the advisories | #53, `CLAUDE.md` |
| `compute_spend/2` with no window covers RunPod's last 30 days | Default to a short window | #58, #62 |
