# Decisions

This page records the choices that still shape ExAtlas, taken from merged PR
bodies and the body of issue #28. It exists so a reader can see what we chose
and what we rejected without reading each PR. PR #70 creates it. Each row
names the PR or issue that holds the reasoning.

## Docs build (#92)

| Decision | Alternative not taken | Where |
|---|---|---|
| Group every public module in the sidebar, `ExAtlas.Application` under Core API | `@moduledoc false` on internals: hiding is an API statement, and a hidden module named in prose is itself a warning | #92 |
| Reword CHANGELOG lines that name removed functions | `skip_undefined_reference_warnings_on`: it suppresses warnings | #92 |
| The `docs` step runs before `hex.audit` in `bin/ci` | Last step: CI stops at `hex.audit` on cowlib, so it would never run | #92 |
| Install pins track the current `@version` major.minor, checked by `docs_test.exs` | Pin ahead to the next release: it does not resolve before publish | #92 |

## Lambda Labs provider (feature #83)

| Decision | Alternative not taken | Where |
|---|---|---|
| Run the container through cloud-init `user_data` and `docker run` | SSH in after boot: no SSH client or private key in the library | #84 |
| Values through `export` lines and `docker run -e NAME` | `--env-file`: it cannot hold a newline, and argv shows in `ps` | #84 |
| The script waits up to 180 s for the Docker daemon before `docker run` | Run at once: cloud-init can reach the script before `docker.service` is up | #89 |
| Region: the first hinted region with capacity, else Lambda's first with capacity | Require `region_hints`: Lambda requires a region, and a full one fails the launch | #84 |
| The GPU count swaps `1x` in the catalog name; a count Lambda does not list is `:validation` before launch | A table per count | #84 |
| SSH key from `provider_opts`, else app config, else `:validation` | The account's only key: implicit | #84 |
| Rebuild `Compute` from instance tags | A local map of ports: lost on restart and on other nodes | #84 |
| Spawn POSTs retry on a 429 only, on both providers | `retry: :transient` for Lambda; RunPod never retried a 429 before | #84, #89 |
| `unhealthy` reads `:running` | `:failed`: it ends a session and deletes the instance on a status that can clear | #84 |
| `raw` drops `jupyter_token` and `jupyter_url`, which carries the same token | Keep `raw` whole | #84, #89 |
| `user_data` stays an `ExAtlas.Secret` until the last Req request step encodes the body | `json:`: Req's `inspect/1` prints `json` in full (risk 26) | #89 |
| A refused launch keeps its status and only Lambda's error `code`, and always withholds Lambda's message | Withhold only a message that contains a value: the review's probes showed echoes quoted (`'\''`), JSON-escaped or cut short pass a substring check | #89 |
| The script finds docker and waits for its daemon, then exports the values and `exec`s `docker run` | Export at the top: a container `PATH` hid docker from the wait loop and the run | #89 |
| Env names starting `DOCKER_` or `LD_` are `:validation` | Allow them: `docker run` reads them on the host, so `DOCKER_HOST` sends every value to another daemon | #89 |
| An image starting with `-` is `:validation` | `--` before the image: docker CLI support unchecked on Lambda's image | #89 |
| A missing API key raises `:unauthorized`, as RunPod does, through the shared `Providers.HTTP.bearer/3` | Return an error tuple for Lambda only | #89 |
| `Providers.HTTP` and `ExAtlas.Auth.for_scheme/1` hold what both providers share | Copy `RunPod.Client` and RunPod's auth minting | #84, #89 |
| The host reports the exit code: a unit runs `docker wait atlas` and POSTs it with the host's `curl` | Trap inside the container, as RunPod does: the image may have no `curl`, and the container holds no key to delete the instance | #85 |
| `command:` with `self_terminate: true` and no callback is `:validation` | Ignore `self_terminate`: it defaults on to stop a bill, and ignoring it would bill silently. Mirrors `spot: true` on RunPod | #85 |
| A transient `systemd-run` unit | Wait in the cloud-init script: cloud-init's final stage would wait on the whole task | #85 |
| The unit's script, URL and token in a `mktemp` file written by the `printf` builtin | `systemd-run --setenv=NAME` with no value: systemd 249 (Ubuntu 22.04) takes only `NAME=VALUE`, which puts the token on argv | #85 |
| curl reads the `Authorization` header from stdin (`-H @-`) | The header on argv, as RunPod's container does: every login on the host sees argv in `ps` | #85 |
| The exports run in a `( ... )` subshell with `docker run` | Export at script level: `DBUS_*`, `SYSTEMD_*` or `TMPDIR` from `env:` would steer `systemd-run` and `mktemp` | #85 |
| The unit starts with any callback, with or without `command:` | Only with `command:`, as RunPod wraps only a command: the host can report the image's own command too | #85 |
| curl retries 5 times, connection refused included | One try, as RunPod's container: `finish` is first-report-wins, and a lost report bills until `max_runtime_ms` | #85 |
| `config :ex_atlas, :lambda_labs, base_url:` for calls with none | A base URL in `Config.build_ctx/2` for every provider: RunPod has two base URLs | #85 |
| An `atlas-created-at` more than 10 minutes ahead reads as absent | Clamp it to now: every list would read the instance as new, so it stays young for ever | #85 |
| RunPod and Lambda share `Providers.Shell` quoting; each keeps its own finish snippet | Share the snippet too, as #85 planned: Lambda's reads the token from stdin on the host | #85 |
| With a callback, a failed `docker run` still starts the unit, which reports 125 for the missing container | Stop the script: the instance billed until `max_runtime_ms` (review finding) | #85 |
| Env names bash keeps for itself (`UID`, `RANDOM`, `BASH_*`, `COMP_*`, ...) are `:validation` | Pass them: `export UID` stops the script, and bash rewrites `RANDOM` (review finding) | #85 |
| The unit deletes its script as it starts | Keep it until reboot: it holds the token | #85 |
| A callback URL with userinfo, a query or a fragment is refused, for every provider | Keep accepting it: `/finish` appended after a query never reached the plug, and userinfo shows in `ps` | #85 |
| `Orchestrator.spawn/1` in interactive mode with Lambda `command:` and `callback:` is allowed; the idle TTL ends it | Refuse it in the orchestrator for every provider without `:self_terminate`: the Mock lacks it too, and interactive Mock sessions with a command would break | #85 |
| One firewall ruleset per instance, attached at launch | Edit the account's global rules: they change every instance on the account, including ones ExAtlas does not own | #86 |
| Every spawn with `ports:` first deletes `atlas-` rulesets that no instance uses | A periodic sweeper process: a new process, and a ruleset in use cannot be deleted anyway | #86 |
| The sweep skips rulesets younger than 5 minutes and deletes at most 10 per spawn | Delete every empty one: a second spawn would delete a ruleset created a moment ago and not launched yet, and Lambda allows about one request a second | #86 |
| Source network `0.0.0.0/0`, or `provider_opts.source_network` | Require `source_network`: RunPod's public ports are open to all today | #86 |
| Ruleset name `atlas-<instance name>-<8 hex>`, cut to Lambda's 64 characters | `atlas-<instance name>`: Lambda's rule on a duplicate name is unknown, and a respawn reuses the name while the old instance still holds its ruleset | #86 |
| `terminate/2` finds the ruleset by `instance_ids` before it terminates, and ignores every ruleset error | Fail `terminate/2` on a ruleset error: the instance is gone, and a retry cannot fix the ruleset | #86 |
| The sweep and `terminate/2` touch only names that match `atlas-...-<8 hex>` | Any `atlas-` prefix: a ruleset you named `atlas-prod` would go (the fresh review's finding) | #86 |
| A launch refused with a 4xx deletes the ruleset; a 5xx or a timeout keeps it | Delete after every error: the delete can land before Lambda attaches the ruleset to an instance it did rent, which then runs with its ports closed | #86 |
| `us-south-1` gets no ruleset | Create one anyway: Lambda's docs say firewall rules do not apply there | #86 |

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
| The reference entrypoint runs the trainer behind a fifo and `wait`, so the exit code is the trainer's | `trainer \| tee`: reports tee's status, and POSIX `sh` has no `pipefail` | #72 |
| A failed pull still uploads the log; an upload failure is printed and the trainer's exit code stands | Skip the upload after a failed pull; fail the task on an upload error | #26, #72 |
| The guide states no Tigris checksum claim; it gives the generic `when_required` fix with AWS's page as source | State that Tigris accepts the default, with no source | #26, #72 |
| The tracker holds `s3:` as a `Spec.Staging`, validated at the top of `Orchestrator.spawn/1`; `Config.build_ctx/2` drops `:s3` | Rely on `format_status/1`: OTP prints a crashing callback's arguments in the stacktrace, outside it | #75 review |
| `api_key:` and the `:auth`, `:headers`, `:aws_sigv4` entries of `req_options:` travel as an `ExAtlas.Secret`, sealed first in `Orchestrator.spawn/1` and `Config.build_ctx/2`, revealed only in `RunPod.Client` | Re-resolve the key from app config on each call: loses per-call keys. Keep a string in the ctx: every provider frame prints it | #76 |
| `ExAtlas.Secret` holds its value in a closure; `Spec.Staging` holds its three credentials as Secrets | A plain field: `inspect(secret, structs: false)` and Erlang's `~p` print it | #76 |
| A crashed poll or billing task exits with `{:crashed, module, stacktrace}`, arities only; the exception struct is dropped | Keep `{exception, stacktrace}`: a frame's arguments and fields like `MatchError.term` can hold the revealed key | #76 review |
| Every guarded public function ends in a clause that raises `ArgumentError` without its arguments | Let the guard fail: `FunctionClauseError` prints the opts | #76 review |
| `inspect(%Spec.Compute{})` hides `auth` whole | A hand-written `Inspect` that shows the scheme and hides the token | #76 |
| A record keeps `s3:`'s endpoint, region and URIs and `credentials: :not_stored`; an adopted task refuses to respawn | Store `s3:` like `env:`: a credential on disk. Re-resolve credentials from app config at adoption: no host asked for it | #26, #74 |
| A record keeps `s3:` fields only from a validated `Spec.Staging`; any other shape keeps the marker alone | Copy the four keys from any map: an unchecked endpoint can carry user info | #74 |
| An adopted tracker marks any `s3:` as not stored, marker or not | Trust the marker: a host store that drops it would respawn with URIs and no keys | #74 |
| Every `env:` value is an `ExAtlas.Secret` from the first entry point on; names stay plain | An `env_secrets:` option or a named list: ExAtlas cannot tell a token from a project name, and one miss prints it | #79 |
| A record keeps `env:` names with `:not_stored` values; an adopted task refuses a respawn that would lose them | Store the values as before: respawn after adoption works, tokens sit on disk | #79 |
| `scrub_keys: [:env]` stores `env: :not_stored`, never nothing | Drop `env:`: an adopted respawn runs with no environment and no error | #79 |
| No record version bump for the `env:` marker | Version 4: a rollback build skips the record and leaves the pod to the Reaper | #79 |
| A record written before #79 keeps its plain values for one adoption; adoption seals them, a respawn sends them, and every rewrite (claim, cost update, respawn) stores names only | Rewrite it with markers at once: breaks tasks in flight across the upgrade. Keep copying the values: each respawn writes the token again | #79, review |
| The string `"not_stored"` counts as the marker | Match the atom only: a store that keeps atoms as strings sends `"not_stored"` to the pod as a value | #79, review |
| `Config.build_ctx/2` drops `env:` | Pass it through: no provider reads it, and every tracker poll printed it | #79 |
| URIs must be `s3://bucket/...`; the endpoint `http://` or `https://` | `https://` only: a local MinIO runs on plain HTTP | #26 |
| ExAtlas never presigns and never calls S3 | Presign in ExAtlas: needs a SigV4 signer and host credentials | #26 |
| Presigned URLs may be `http://` or `https://`, need a host, and carry no user info | `https://` only: a local MinIO runs on plain HTTP | #26, #73 |
| `Spec.Staging` holds `dataset_url` and `artifact_url` as `ExAtlas.Secret`s | Plain strings left out of `Inspect`'s `only:` list: `structs: false` and `~p` print them | #73 |
| The entrypoint downloads the dataset archive to a file, then runs `tar -xf` | `curl \| tar -x`: GNU tar detects no compression on a pipe, and the pipe hides curl's exit code | #73 |
| The artifacts and the log go up as one `.tar.gz` built with `tar -czf` | `tar \| gzip`: POSIX `sh` cannot read tar's exit code in a pipe | #73 |
| Presigned URLs need an object path and only RFC 3986 characters after the host, no `{ } [ ]` | Scheme and host only: curl globs `{ }` and `[ ]` and prints the whole URL in its error; `curl -T` appends a file name to a URL with no path | #73 review |
| The entrypoint unsets both URLs before the trainer starts, and calls curl with `-q -g -f` and a stall limit | Leave them exported: a trainer that dumps its environment prints them. Plain `curl -f`: a `.curlrc` can turn on `--verbose` | #73 review |
| A URI and a URL for the same side: the URI wins and the script prints which variable it ignored | Refuse both in `Staging.new/1`: blocks an image that reads only one of them | #73 |

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
| A respawn after adoption asks a host resolver, an `{m, f, args}`, for `s3:` and `env:` | A function capture: a record must survive DETS and a restart | #87 |
| The per-task tuple wins; `config :ex_atlas, :orchestrator, respawn_credentials:` is the fallback | App config only: credentials are often per user or per task | #87 |
| Resolve at respawn, not at adoption | Resolve when adopting: most adopted tasks never respawn | #87 |
| The resolver returns `s3:` whole; `info.s3` gives the stored parts without the marker | ExAtlas merges keys onto the stored parts: presigned mode stores no URL | #87 |
| `env:` must cover every stored name and replaces the stored env whole | Run with the names it returns: a container would miss a value it was rented with | #87 |
| The resolver runs in a task under the poll `Task.Supervisor`, bounded at 30 s; a raise, throw or exit is caught inside it, so no crash report prints its value | Call inline: a hung resolver would hold the tracker forever | #87 |
| Resolved values stay in the tracker's opts, so a second respawn in the same VM reuses them | Call the resolver on every respawn | #87 |
| The spawn checks that the resolver function is exported | Check the shape only: a typo would surface hours later, at the respawn | #87 |
| Only a module that declares `ExAtlas.Orchestrator.RespawnCredentials` is called, on the spawn option, an adopted record and the app config | Call any exported function: write access to the store would run `{:os, :cmd, [...]}` on the node | #87 |
| The resolver's result is checked inside its task | Check in the tracker: a check that raises on a value would crash it and print the value | #87 |
