# Decisions

This page records the choices that still shape ExAtlas, taken from merged PR
bodies and the body of issue #28. It exists so a reader can see what we chose
and what we rejected without reading each PR. PR #70 creates it. Each row
names the PR or issue that holds the reasoning.

## Database tracking store (milestone 9)

| Decision | Alternative not taken | Where |
|---|---|---|
| The node signs every tracking record it writes (HMAC-SHA256, key derived from `config :ex_atlas, :callback, secret:` with its own salt, over the whole record), and an adopted task respawns only from a record whose `:mac` checks | Re-validate the stored callback descriptor field by field: no field check tells a forged `task_id`, image or command from a real one | #131 |
| An unsigned or mismatched record adopts (deadline, polls, cost cap) and refuses only the respawn | Refuse to adopt it: a 0.8.0 task in flight across the upgrade loses its deadline. Trust it: a writer drops the `:mac` | #131 |
| A rewrite re-signs only a record whose stored `:mac` checked, read from the store at that moment | Re-sign what the tracker trusted at adoption: an edit made after adoption would come back signed | #131 |
| The signing key comes from the callback secret; a node without one writes unsigned records and warns at a respawnable `persist: true` spawn | A new `record_secret:` setting: every host would need it | #131 |
| An adopted task takes `:base_url` and `:req_options` from `config :ex_atlas, <provider>`, as `:api_key`; a record stores neither, and every rewrite drops them from an older one | Keep storing them and refuse a record whose URL differs from config: it still reads a value the store's writer chose, and refuses live pods after a host changes its URL | #125 |
| An adopted task drops every credential key from its record's opts too (`:api_key` and the rest of `scrub_opts/1`'s list) | Trust a stored `:api_key` as a per-call one: it would point polls and the respawn's rent at the writer's account (review finding) | #125 |
| Drop all of `:req_options` from the record | Drop a list of Req keys (`base_url`, `plug`, `connect_options`): Req adds keys, and a deny-list misses them | #125 |
| `Config.build_ctx/2` reads `base_url:` and `req_options:` from every provider's app config; per-call `req_options` merge over config key by key | Keep #85's per-client `base_url:` fallback: RunPod had none, so an adopted RunPod task would lose a proxy. On RunPod it sets the management URL, as a per-call `base_url:` does | #125 |
| The Adopter adopts a record only when its provider is built in or declares `@behaviour ExAtlas.Provider` | Tighten `Config.provider_module/1` for every call: a caller's own `provider:` is trusted code | #125 |
| The host starts `ExAtlas.Orchestrator.Supervisor` after its repo | The Ecto store waits or retries for the repo inside ExAtlas's tree: a retry still answers `all/0` with an error at boot, which shuts the Reaper for that boot | #120 |
| `start_orchestrator: true` plus the host's child refuses to start, naming both | Start a second tree: it crashes on duplicate names | #120 |
| The record is one `term_to_binary` column, plus an `owner` column for queries | A column per field: every new record field needs a migration | #120 |
| Rows decode with `Plug.Crypto.non_executable_binary_to_term/2` and `[:safe]`; a row that is not a map with its own `id` is refused | Plain `binary_to_term/1`: anyone who can write the database could create atoms or plant functions | #120 |
| One row that will not decode makes `all/0` return `{:error, {:undecodable, ids}}` | Skip the row: its pod would have no record, and the Reaper would delete it | #120 |
| `get/1` raises on a row that will not decode or a database that is down | Answer `:error`: the Reaper reads it as "not ours" and deletes the pod | #120 |
| `put/1` and `delete/1` log a database failure and return `:ok` | Raise: the tracker crashes and deletes its pod | #120 |
| A tracker logs a raise from its store and runs on; on a node stop it keeps the pod | Crash: a crashed tracker deletes a pod the store may still hold | #120 |
| No `:repo` raises `ArgumentError` at boot; a missing table answers `{:error, _}` | Log and run: a config mistake would surface only at a deploy | #120 |
| The repo comes from `config :ex_atlas, :orchestrator, repo:` | Child opts: `put/1`, `get/1` and `all/0` take no opts | #120 |
| Migration steps create only what is missing; `version:` names the last step to run | A version stored in the table, as Oban does: more code for a one-step table | #120 |
| A row over 1 MiB (bytes) or a compressed row is refused; `put/1` writes nothing over 1 MiB | Trust `[:safe]`: it accepts a compressed term that declares up to 4 GB decoded | #123 review |
| Writes run in a `Task`, outside any caller transaction | Write in the caller's process: a host rollback erases the record of a running pod | #123 review |
| The store's `start_link/1` refuses when the repo is not running | Refuse only the duplicate tree: `start_orchestrator: true` with the Ecto store would boot with an unreadable store every time | #123 review |
| One refused row still fails `all/0`. Since `get/1` raises on that row and the Reaper treats a raise as "ours", skipping it would also keep its pod; we keep the design's rule, which adopts nothing that boot | Skip the row as the Adopter skips a record of an unknown version: the other records get trackers | #120, #123 review |
| `ensure_running!/0` checks that `ComputeSupervisor` is alive | Check `start_orchestrator`: it is false for a host-started tree | #120 |
| Tests run on SQLite (`ecto_sqlite3`, test only) | Postgres: every checkout would need a database server | #120 |
| The table is `atlas_tracking_records` in the repo's default prefix; MySQL is not supported | A configurable name or prefix: no host has asked. MySQL's upsert takes no conflict target | #120 |
| The installer writes `config/config.exs`, turns a `start_orchestrator: true` there off, and only warns about one in another file | Edit `runtime.exs`: it often sets the flag under a condition | #128 |
| A repo the installer cannot find in the application's `children` stops the whole install | Write the config and warn: `start_orchestrator: false` with no supervisor child leaves the host with no orchestrator | #128 review |
| The installer reads `config` calls at any depth and in the `config/3` form | Igniter's top-level reader: it missed `start_orchestrator: true` under `if config_env() == :prod`, which crashes the prod boot | #128 review |
| A repo's literal `priv:` moves the migration; another value is ignored | Refuse a repo with `priv:`: most hosts set it as a literal | #128 review |
| `--repo` accepts any module the project defines | Only modules that `use Ecto.Repo` directly: a repo built on a host's wrapper module was refused | #128 review |
| Several repos and no `--repo` stop the install with an issue naming them | Igniter's interactive picker: a scripted or `--yes` run would block or guess | #128 |
| The installer inserts the supervisor right after the repo itself | `Igniter.Project.Application.add_new_child(after: [repo])`: in Igniter 0.8.4 it lands one child late, after the Endpoint in a `phx.new` app | #128 |
| A migration that already calls the store's Migration module stops a new one | Check the migration module's name: a host that followed the README named its own | #128 |
| The reap-owner notice fires on `start_orchestrator: true` or on any module naming `ExAtlas.Orchestrator.Supervisor` | Check the application module only: a host may start it in a nested supervisor | #128 |
| Both conformance suites ship in `lib` and call ExUnit only inside their `quote` | Keep them in `test/support`: the guides tell hosts to `use` them | #128 |

## Vast.ai provider (feature #98)

| Decision | Alternative not taken | Where |
|---|---|---|
| Rent the cheapest of the first 3 matching offers, the next on a refusing 4xx | Rent only the first: offers are taken within seconds | #99 |
| Never retry a rent after a 5xx or a timeout | Retry as a read does: a second GPU nothing tracks | #99 |
| A refused rent keeps Vast's `error` code and withholds `msg` | Pass the message through: it can echo `env` | #99 |
| `raw` keeps an allow-list of instance fields | Drop `extra_env`, `onstart` and `jupyter_token`: `image_args` and any field Vast adds later would pass, on instances ExAtlas did not start too | #99 |
| A rent and a Lambda launch follow no redirect | Req's default, which resends the body to the `Location` host | #99 |
| `runtype: "args"` with no `args` | `ssh`, vast-cli's default, which replaces the image's entrypoint | #99 |
| `env` as a JSON object, names limited to `[A-Za-z_][A-Za-z0-9_]*` | The Docker-flag string the reference shows; a free name is a Docker flag | #99 |
| `cancel_unavail: true` on every rent | Vast's default, which can create a stopped instance that bills its disk | #99 |
| `ATLAS_PORTS` in the container env records each port's protocol | Read every port as `:tcp`: Vast's port map holds numbers only | #99 |
| `list_gpu_types/1` searches once per catalog GPU | One search: Vast returns at most 64 offers, the cheapest few GPUs | #99 |
| `command:` goes to the image's entrypoint as `args`, wrapped in `sh -c` | Override the entrypoint with `onstart: "sh"`: `command:` would mean something else than RunPod's `cmd`, and an image's setup entrypoint would not run | #105 |
| One trap wrapper in `Providers.Shell` for RunPod and Vast | A Vast-only script: the two would fail differently | #105 |
| The container's DELETE reads `$CONTAINER_ID` and calls `console.vast.ai` | The instance id in the body, which exists only after the rent answers; the configured `base_url`, a test or proxy host the container would send its key to | #105 |
| Curl reads the Bearer header from stdin (`-K -`), written by the `printf` builtin | `-H` on argv, which `ps` shows to every process in the container | #105 |
| The wrapper checks the id (`[A-Za-z0-9_-]`) and each key or token (`[A-Za-z0-9._-]`) before it sends, and skips the request otherwise | Escape the value into curl's config syntax: one missed character class sets any curl option | #105 |
| A SIGTERM to the wrapper's shell waits for the command, as `sh` does | Run the command in the background and forward the signal: a RunPod spot stop would then report an exit code, and read as a failed task, not a preemption to respawn | #105 |
| A `spot: true` rent bids at the offer's `min_bid` | A margin above it: the respawn covers an outbid instance and a margin costs every hour. `provider_opts: %{bid_price: n}` is the later alternative | #112 |
| An offer with no positive numeric `min_bid` is skipped | Rent it at `dph_total`, which bills an interruptible instance at the on-demand price | #112 |
| `spot: true` with `provider_opts.offer_id` is `:validation` | Look the offer up first: a second request for a path that is an escape hatch | #112 |
| `list_gpu_types/1` makes a second, `type: "bid"` search per GPU for `spot_price_per_hour`, four searches at a time; a failed bid search leaves it `nil` | Read `min_bid` off the on-demand offers: their `dph_total` is not what a bid bills. Fail the call on a bid error: it would lose the on-demand prices | #112 |
| A spot pick sorts by `dph_total`, and `cost_per_hour` is that `dph_total` | Sort by `min_bid`: Vast's free search lists a bid offer's `dph_total` as `min_bid` plus storage and sorts by it, so a dearer disk would win on `min_bid` and bill more | #112 |
| A spot `command:` with no `callback:` is allowed, and the docs say to pass one | `:validation` as on Lambda: a spot task with `self_terminate: false` or its own checkpoints runs fine without one | #112 |
| `stop/2` and `start/2` return `:ok` on Vast's acceptance | Poll until the instance reads `exited`: the tracker already polls | #116 |
| A refused stop or start keeps Vast's `error` code and withholds `msg`; a 404 stays `:not_found` | Pass the message through, as for a refused rent | #116 |
| `compute_spend/3` snaps `from` down to the UTC day and reports the snapped window | Pass `from` as is: Vast's charges take a day range | #116 |
| With no `from`, `compute_spend/3` reads the instance's `start_date` | A fixed 30-day window, as RunPod's default | #116 |
| The bill's total is the rows' `amount`; bandwidth counts in the total only | Sum the items: it would drop a charge type the items omit | #116 |
| `Spend.raw` keeps an allow-list of row and item fields | Keep Vast's body: a row's `description` and `metadata` hold the instance label | #116 |

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
| `config :ex_atlas, :lambda_labs, base_url:` for calls with none (moved into `Config.build_ctx/2` for every provider by #125) | A base URL in `Config.build_ctx/2` for every provider: RunPod has two base URLs | #85 |
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
| `RunPod.Translate.pod_to_compute/2` drops `"env"` from `raw` | Redact the tracker's `:message` in `format_status/1`: the poll reply never reaches it. Allow-list `raw`: it stays the fields ExAtlas does not normalize | #126 |
| `RunPod.Translate` drops `"env"` (and an embedded `template`'s) from `Endpoint.raw` and `Template.raw`; `HTTP.handle_response/3` drops it from a non-2xx body before `Error.raw` | A copy of the scrub in `Error` and `Translate`. Allow-list `raw`. Drop `Template.env` too: it is the field callers read | #133 |
| `HTTP.drop_env_deep/1` drops every `env` key (string or atom) at any depth from an error body before `Error.raw` | Reuse the targeted `drop_env/1`: it misses a wrapped or atom-keyed body. Make `drop_env/1` recursive: a successful body's `raw` keeps unknown nested fields | #136 |
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
| Owner leases live in the store's database, in `atlas_owner_leases` | Erlang clustering: Fly machines on one account often run unclustered | #132 |
| Each record is claimed by its own conditional `UPDATE` that writes owner and signed blob together and re-checks the old owner and its expired lease | One bulk `UPDATE` of the owner column: the blob and its signature would still name the dead owner | #132 |
| `claim_expired/3` takes a rewrite function; ExAtlas signs, the store writes | The store signs: signing stays in one module | #132 |
| A takeover claims only records this node's key verifies | Claim any record: an unsigned record can name any pod of the account, and the deadline would delete it (#138) | #132 |
| `lease_ttl_ms` defaults to 90 s, renewed every third, bounded 1 s to one hour | A shorter TTL: a GC pause or slow database must not hand a live node's tasks away. No upper bound: a dead node's tasks would wait out any TTL | #132 |
| A node that cannot renew its own lease claims nothing | Claim anyway: the node that cannot renew may be the one cut off | #132 |
| Expiry uses the renewing node's wall clock | The database clock: `now()` arithmetic differs between Postgres and SQLite | #132 |
| A node whose renewal comes late stops its trackers of records another node claimed, with `:shutdown` | Leave them: two trackers on one pod both respawn on a preemption | #132 |
| Only the Ecto store implements leases | A DETS version: DETS is local to one machine | #132 |
| A node claims only after it held its own lease a full ttl without a gap | Claim on the first renewal: after a database outage the first node back takes every live node's tasks | #132 |
| Every renewal releases trackers whose record names another owner | Only after a lapse the node's own clock saw: skew, a late write, a forged expiry or a claim before the first renewal go unseen | #132 |
| A released tracker keeps its pod and record, even holding a finish report | Stop with `:shutdown`: a reported task deletes the pod and the new owner's record | #132 |
| Claimed records are adopted in a task under the poll `Task.Supervisor`, one takeover at a time | Inline: a slow provider holds back the renewal, and the node's own lease lapses | #132 |
| A claim requires the record's signed `:owner` to match the `owner` column | Trust the column: a database writer moves one live record to a made-up expired owner | #132 |
| A claim skips signed records this build would not adopt (`Adopter.refusal/1`) | Claim and skip at adoption: in a rolling deploy the older node owns records nobody tracks | #132 |
| No Lease on a node with no callback secret | Start it: it verifies no record, and its own records are unsigned | #132 |
| No `mix ex_atlas.upgrade` notice for migration step 2 | A `"0.9.0"` upgrader: the Ecto store is unreleased, so no Hex host ran step 1 alone; the README and CHANGELOG say what to add | #132 |
| Optional provider callbacks go through `dispatch_optional/3` | Call the module directly: raises on providers without the callback | #60, `CLAUDE.md` |
| `hex.audit` stays in CI and suppresses nothing, even though it fails on cowlib | Ignore the advisories | #53, `CLAUDE.md` |
| `compute_spend/2` with no window covers RunPod's last 30 days | Default to a short window | #58, #62 |
| A respawn after adoption asks a host resolver, an `{m, f, args}`, for `s3:` and `env:` | A function capture: a record must survive DETS and a restart | #87 |
| The per-task tuple wins; `config :ex_atlas, :orchestrator, respawn_credentials:` is the fallback | App config only: credentials are often per user or per task | #87 |
| Resolve at respawn, not at adoption | Resolve when adopting: most adopted tasks never respawn | #87 |
| A callback token signs its pod's attempt; a report from an earlier attempt gets 410 | A new `task_id` per pod: it names the Limiter bucket, the record and `ATLAS_TASK_ID` | #100 |
| The Registry value holds the current attempt, and the tracker checks a queued report again | A `GenServer.call` from `ingest/3`: delivery must stay a `send` | #100 |
| A token with no attempt, as 0.8.0 minted it, is accepted unchecked | Read it as attempt 0: a respawned 0.8.0 pod's real report would get 410 | #100, replaced by the next two rows |
| A token with no attempt is accepted only while the tracker's current pod holds such a token too: the Registry value is `:claimless` until the first respawn this version makes | Reject it always (every running 0.8.0 pod loses its reports); accept it for a deprecation window with a warning (leaves the hole open); read it as attempt 0 (refuses a pod 0.8.0 itself respawned) | #110 |
| A respawn writes the replacement's attempt into the stored record's callback descriptor | Read `respawns` at adoption: it cannot tell a pod 0.8.0 respawned from one this version did | #110 |
| A bare `task_id` passed to `ingest/3` stays unchecked, whatever the current pod holds | Refuse it once a pod signs an attempt: it breaks every hand-rolled controller that passes `claims.task_id` | #110 |
| `:vast` stays out of the default `reap_providers` | Add it: the `atlas-` prefix and owner segment are text a user can type into a Vast label, so a default Vast Reaper can delete an instance ExAtlas never rented. A marker no user types by accident would make it safe | #118 |
| `spawn/1` warns, on every spawn, when `on_failure` allows a respawn and the provider is outside `reap_providers`, for any provider | Warn for `:vast` alone; warn once per boot (needs global state) | #118 |
| The tracker checks reports against the attempt in its opts' callback descriptor; `respawns` counts the budget | Keep comparing with `respawns`: after an interrupted adoption the record's pod holds `respawns - 1` | #118 |
| An interrupted adoption accepts the record's pod once a poll reads it alive | Refuse every token until the next respawn or the deadline | #118 |
| A provider list that raises or exits skips that provider for the tick and logs only the error's kind | Let the tick crash: the restarted Reaper stays gated for the boot (#122) | #118 |
| The Adopter records its outcome in `:persistent_term`, keyed by the pid of the supervisor it shares with the Reaper; a restarted Reaper reads it on init | A boot epoch, a `make_ref/0` in both child specs: it edits the child list #120 moves. ETS: needs an owner process. The app env: hosts and tests reset it | #122 |
| The Adopter writes before it signals | The Reaper writes when the message arrives: a signal sent while the Reaper is down is lost | #122 |
| A host-prepared callback descriptor starts at attempt 0 | Keep its attempt: the first respawn would issue it again | #118 |
| The resolver returns `s3:` whole; `info.s3` gives the stored parts without the marker | ExAtlas merges keys onto the stored parts: presigned mode stores no URL | #87 |
| `env:` must cover every stored name and replaces the stored env whole | Run with the names it returns: a container would miss a value it was rented with | #87 |
| The resolver runs in a task under the poll `Task.Supervisor`, bounded at 30 s; a raise, throw or exit is caught inside it, so no crash report prints its value | Call inline: a hung resolver would hold the tracker forever | #87 |
| Resolved values stay in the tracker's opts, so a second respawn in the same VM reuses them | Call the resolver on every respawn | #87 |
| The spawn checks that the resolver function is exported | Check the shape only: a typo would surface hours later, at the respawn | #87 |
| Only a module that declares `ExAtlas.Orchestrator.RespawnCredentials` is called, on the spawn option, an adopted record and the app config | Call any exported function: write access to the store would run `{:os, :cmd, [...]}` on the node | #87 |
| The resolver's result is checked inside its task | Check in the tracker: a check that raises on a value would crash it and print the value | #87 |
| A finish report ends an interactive session whose non-empty `command:` self-terminates, after `finish_grace_ms`; `touch/1` does not postpone it | Refuse interactive `command:` on Lambda: breaks interactive Mock and RunPod sessions with a command, and a finished instance still bills | #96 |
| Interactive `max_runtime_ms` and `ready_timeout_ms` announce `{:terminating, :max_runtime \| :never_ready}` | Keep `{:task, _}`: `Events` reserves task events for `mode: :task` | #96 |
