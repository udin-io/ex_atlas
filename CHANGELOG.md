# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAtlas adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- **`await_ready/2`: block until a compute is usable** (#22). `spawn_compute/1`
  returns when the provider accepts the rental, minutes before the container
  can serve traffic, and every caller was writing the same spawn → poll →
  check-status loop by hand.

  Two entry points, one result shape (`t:ExAtlas.await_result/0`):

      # Untracked — a bare spawn, a script, a mix task. Polls get_compute/2.
      ExAtlas.await_ready(id, provider: :runpod, timeout_ms: 120_000)

      # Tracked — subscribes to the ComputeServer's existing status stream.
      ExAtlas.Orchestrator.await_ready(id, timeout_ms: 120_000)
      # {:ok, %Compute{status: :running}}
      # | {:error, {:timeout, last_seen_compute_or_nil}}
      # | {:error, {:dead, :failed | :stopped | :terminated | :vanished | :preempted, compute_or_nil}}

  What the ticket asked for that is no longer needed: it also proposed that
  `ComputeServer` poll upstream and broadcast `{:status, :running}` when the
  pod is actually up. #24 shipped exactly that, so a *tracked* compute already
  announces readiness. `Orchestrator.await_ready/2` therefore subscribes to
  that stream rather than opening a second poll — awaiting ten pods costs the
  provider nothing beyond the ten polls already running — and reads the
  tracker's state after subscribing so a resource that came up in between is
  not missed. An untracked id falls back to the polling path, so one call
  covers both.

  `{:poll_failed, _}` does not resolve the wait: a 5xx, a rate limit or a
  socket error is "we could not tell", so the wait backs off (reusing
  `UpstreamStatus.next_interval_ms/3`) and continues to its timeout. Timing out
  terminates nothing and hands back the last observed `Compute`, per the
  ticket. Readiness means observed `:running` and deliberately *not* "running
  with ports populated" — a port-less `run_task/1` pod would never satisfy
  that.

  Across an `on_failure: {:respawn, n}` respawn the wait follows the
  replacement on the *original* deadline. Getting that right meant fixing a
  real ordering bug the tests found: `ComputeServer` broadcasts the death cause
  *before* deciding whether to respawn, so a naive wait reported a preempted-
  then-replaced session as over. A cause is now held until the tracker confirms
  it by stopping.

- **Pod→host callback boundary: progress, logs and exit codes** (#25).
  ExAtlas gains its first *inbound* external boundary. A running container can
  now POST progress, stream log lines, and declare its exit code before it
  goes, and the orchestrator relays all three on the existing
  `"compute:<id>"` topic as `{:progress, payload}`, `{:log, payload}` and
  `{:task_report, %{exit_code: n}}`.

  New modules: `ExAtlas.Callback` (framework-free core — `verify/1`,
  `ingest/3`, `prepare/1`), `ExAtlas.Callback.Plug` (the shipped HTTP
  boundary, behind a new **optional** `:plug` dependency),
  `ExAtlas.Callback.Token` (stateless signed credential) and
  `ExAtlas.Callback.Limiter` (per-task, per-kind ETS token bucket).

  Turn it on with `callback: "https://app.example.com/atlas/cb"` on
  `spawn/1`/`run_task/1` (or `config :ex_atlas, :callback, base_url: ...`),
  a `secret:` in the same config block, and
  `forward "/cb", ExAtlas.Callback.Plug` in your router.

  Why a `task_id` and not the compute id, as the ticket proposed: RunPod
  assigns the compute id in the `POST /pods` *response*, so nothing can bind a
  token to it while the container environment is still being built. The task id
  is minted before the provider call, and it survives an
  `on_failure: {:respawn, n}` swap, where a compute id would not.

- **`:completed` is now provable, and the spot ambiguity is closed** (#25).
  `ExAtlas.Orchestrator.TaskOutcome.classify/3` takes the recorded report:
  a clean exit turns an inferred completion into a proven one, a non-zero exit
  becomes `{:task, {:failed, {:exit_code, n}}}` — the existing failure shape,
  so no subscriber breaks — and a preemption observed after a clean report
  reads as `:completed`. A compute that reported `finish` is never respawned,
  so `on_failure: {:respawn, n}` can no longer re-run work that already
  finished. With no report, `classify/3` is byte-identical to `classify/2`.

- **`:finish_grace_ms` (default 60s) fixes `self_terminate: false`** (#25).
  A one-shot armed by the first report. When the report lands but the resource
  never disappears — a skipped trap, an image without `curl`, a `DELETE` that
  failed — the task finishes on the report and teardown issues the `DELETE`
  that stops the meter. Those tasks could previously only ever end as
  `:timed_out`.

- **`ExAtlas.Orchestrator.run_task/1` — run a container to completion** (#21).
  The third compute shape, alongside interactive per-user pods and serverless
  jobs: run this image with this command until it exits, report the outcome,
  destroy the resource. Broadcasts `{:task, :completed}`,
  `{:task, :timed_out}` or `{:task, {:failed, reason}}` before the existing
  `{:terminating, _}` / `{:status, :terminated}` pair.

  It is the same `ComputeServer` in `mode: :task`, not a second server: that
  module already owns `trap_exit` plus a `terminate/2` that guarantees the
  `DELETE`, the shutdown budget that lets it finish, the offloaded status
  poll, "uncertainty never tears a resource down", and registry re-keying on
  respawn. Task mode adds `:max_runtime_ms` and `:ready_timeout_ms` timers,
  removes the idle clock, and defers the one mode-dependent decision to the
  new pure `ExAtlas.Orchestrator.TaskOutcome`.

- **`:command` and `:self_terminate` on `ExAtlas.Spec.ComputeRequest`** (#21).
  `:command` maps to RunPod's `dockerStartCmd`, previously reachable only via
  the `:provider_opts` escape hatch. `:self_terminate` (default `true`) wraps
  it in a shell that deletes the resource when the command ends, using the
  `RUNPOD_POD_ID` and pod-scoped `RUNPOD_API_KEY` RunPod injects, with a
  `trap` so a crash cleans up too.

  This is not a convenience. RunPod's REST v1 `Pod` schema exposes no
  container state — no `runtime` object, no `currentStatus`, no exit code —
  and `desiredStatus` is a *desired* state that only changes when someone asks.
  So a pod whose `dockerStartCmd` has exited keeps reporting `RUNNING` and
  keeps billing, and polling can never notice. Self-termination is the only
  source of a normal-exit signal; `:max_runtime_ms` is the only cover for the
  cases where nothing in the container can run (SIGKILL, OOM kill, a hung
  process, a failed image pull, `self_terminate: false`). Both are required
  and neither is sufficient alone, so `run_task/1` defaults both on.

- **`ExAtlas.Orchestrator.info/1` reports `:mode` and
  `:max_runtime_remaining_ms`** (#21), so a UI can show how much of a task's
  wall-clock budget is left.

- **`:self_terminate` capability atom**, reported by RunPod.

### Fixed

- **`created_at` is populated for RunPod pods again** (#21) —
  `Translate.parse_created_at/1` read `pod["createdAt"]`, which does not exist
  on RunPod's REST v1 `Pod` schema; its only machine-readable timestamp is
  `lastStartedAt`. So `Compute.created_at` was `nil` for every RunPod pod,
  `Reaper.young?/3` fell through to its `false` catch-all, and the
  `:reap_grace_ms` window shipped in #24 was inert against the one provider it
  was written for — leaving the spawn race it exists to close wide open.

- **Request options are routed by request type** (#21) — `spawn_compute/1` and
  `run_job/1` split their options against a single shared key list holding the
  union of both request structs' fields, so each handed the other's options to
  its own builder and `NimbleOptions` raised on a key merely addressed
  elsewhere: `spawn_compute(gpu: :h100, mode: :async)` died on
  `unknown options [:mode]`.

### Removed

- The unreachable `desiredStatus: "FAILED"` clause in RunPod's pod-status
  translation. The enum is exactly `RUNNING | EXITED | TERMINATED`; an
  unclassifiable status now falls through to `:provisioning`, which
  `UpstreamStatus` counts as alive rather than as a death.

### Security

- The pod callback endpoint is internet-reachable and every byte on it comes
  from a container ExAtlas does not control, so the library ships the
  dangerous parts rather than documenting them (#25): body caps applied by
  `read_body/2` **before** any JSON decode and without consulting the
  attacker-written `content-length`; constant-time verification via
  `Plug.Crypto`; a per-task, per-kind rate limit with swept buckets; distinct
  401/410/413/429 responses, none of which reveals to an unauthenticated
  caller whether a task id exists; `send` rather than `GenServer.call`, so a
  web request can never block on the orchestrator's mailbox; no atom ever
  created from client input; and no response body that echoes the token.

- Callback URLs are validated at the `spawn/1` seam, *before* the provider is
  called, and a non-`https`, loopback, RFC 1918, link-local or `.local` host is
  refused unless `allow_insecure_callback: true` (#25). Validating after the
  resource existed would leak a live, billing pod behind a raise, and a
  callback that silently never arrives is worse than no callback at all.

- `:max_runtime_ms` remains authoritative: a pod cannot extend its own budget
  by staying quiet or by talking. `progress` deliberately does **not**
  `touch/1`, so a compromised pod cannot defeat its own idle TTL (#25).

## v0.5.0 — unreleased

Closes all remaining audit items. Library is now at feature parity with
the audit recommendations.

### Fixed

- **A malformed pod body no longer raises** (#24) —
  `ExAtlas.Providers.RunPod.get_compute/2` piped the response body straight
  into a translator guarded on `is_map/1`, so a 200 carrying `null` raised a
  `FunctionClauseError` at the call site. It now returns an
  `%ExAtlas.Error{kind: :provider}`, which matters because the status poller
  runs this call in a loop inside a GenServer.

- **Provider-specific options reach the provider ctx** (#20) —
  `ExAtlas.Config.build_ctx/2` only kept `:provider`, `:api_key`,
  `:base_url` and `:req_options` and dropped everything else, so the
  documented `ExAtlas.get_job(id, provider: :runpod, endpoint: "abc123")`
  (and `cancel_job/2`, `stream_job/2`) could never succeed — RunPod reads
  `:endpoint` from the ctx and returned a `:validation` error every time.
  Remaining options are now passed through to the ctx verbatim; the four
  options ExAtlas resolves itself still win.

### Added

- **Upstream status polling** (#24) — the `ComputeServer` heartbeat only ever
  compared local timestamps, so a pod that died on the provider's side (host
  failure, crash-looping image, spot preemption) was never noticed:
  subscribers kept believing the session was healthy until the idle TTL fired
  and ExAtlas tried to terminate something long gone. Each tracker now runs a
  second, independent clock — `:status_poll_ms`, default `60_000`, `false` to
  disable — that calls `get_compute/2`, broadcasts upstream status changes
  while the resource is alive, and broadcasts the cause of death before
  stopping.

  - New `{:status, :failed | :stopped | :vanished | :preempted}` and
    `{:poll_failed, error}` events. **A failed poll is not a death**: only a
    404 means the resource is gone, so 5xx, rate limits, socket errors,
    malformed bodies and bad API keys back the poller off instead of ending
    the session.
  - `:preempted` is *inferred* — no provider publishes a preemption signal —
    for resources spawned with `spot: true` that stop, are terminated, or
    vanish unbidden.
  - Optional `on_failure: {:respawn, max_attempts}` replaces a preempted
    resource from the same opts, terminating the old one if the provider still
    has it, re-keying the tracker under the new id and emitting
    `{:respawned, new_id}` on the old topic. The id travels alone — the
    replacement's URL and bearer token are read back with
    `ExAtlas.Orchestrator.info/1` rather than broadcast.
  - The poll itself runs in a supervised task rather than in the tracker's
    callback, so a slow or hanging provider can't delay `touch/1`, `info/1` or
    — the expensive one — teardown, which has to win the race to issue its
    `DELETE`. Raises on the poll path are reported as `{:poll_failed, _}` too:
    the tracker never tears a resource down on uncertainty.
  - `:reap_grace_ms` (default: one reap interval) keeps the Reaper off
    resources too young to have a tracker yet — every resource is created
    upstream before it is registered.
  - Tracking options are validated at the `ExAtlas.Orchestrator.spawn/1`
    boundary, before the provider is asked for anything.
  - `ExAtlas.Orchestrator.UpstreamStatus` exposes the classification and the
    jittered/backing-off poll schedule as a standalone primitive.
  - `ExAtlas.Providers.Mock.set_status/2` and `forget/1` let consumers
    simulate upstream deaths in their own tests.

- **`ExAtlas.Fly.Supervisor`** (E3) — top-level supervisor for the Fly
  sub-tree, exposed as a `child_spec/1` so hosts can embed ExAtlas under
  their own supervision tree. `ExAtlas.Application` delegates to its
  `fly_children/0` to avoid duplication.
- **`ExAtlas.Fly.Tokens.refresh/1`** (E5) — atomic invalidate-then-acquire.
  Equivalent to `invalidate/1` + `get/1` but runs under a single
  GenServer call on the AppServer, closing the race where a concurrent
  caller acquires between the two.
- **`ExAtlas.Fly.Dispatcher.subscribe_with_backpressure/2`** (E6) — opt-in
  eviction watchdog. Monitors the subscriber's message queue and signals
  an eviction via `{:ex_atlas_fly_backpressure_evict, topic}` if the
  queue exceeds a configurable threshold.
- **Proactive soft-expiry refresh** (E7) — `ExAtlas.Fly.Tokens.AppServer`
  schedules a background refresh `:soft_expiry_lead_seconds` (default 3600)
  before a cached token's `expires_at`. Avoids the expiry cliff where
  every caller around expiry hits the CLI at once.
- **Monorepo discovery** (M4) — `ExAtlas.Fly.Deploy.discover_apps/2`
  now accepts a `:max_depth` option. Default `1` preserves current
  behavior; set higher for `apps/<name>/fly.toml` layouts.
- **Streamer shutdown signal** (L5) — the Streamer sends a final
  `{:ex_atlas_fly_logs_stopped, app_name}` on its topic when it
  terminates, so subscribers can unsubscribe themselves from the
  framework-agnostic dispatcher.

### Changed

- **`ExAtlas.Fly.Deploy.deploy/2`** (M5) — now returns
  `{:error, {:fly_error, :not_found, _}}` when `fly` is not on `PATH`,
  matching `stream_deploy/3`. Previously raised `ErlangError` from
  `System.cmd/3` on missing executables.
- **`ExAtlas.Fly.Deploy.parse_app_name/1`** (L3) — tightened regex:
  quoted values must not contain whitespace (pre-fix `app = "my app"`
  returned `{:ok, "my"}`). Still accepts unquoted values and
  whitespace-separated inline comments on the `app =` line.
- **`ExAtlas.Fly.Logs.Streamer` L7 race fix** — until the first
  subscriber registers via `subscribe_pid/2`, the Streamer advances its
  cursor silently without dispatching. Previously the very first poll
  could fire before a caller's `subscribe_pid/2`, dropping the first
  batch onto a zero-subscriber topic.
- **`ExAtlas.Fly.Logs.Streamer.subscribe/2`** (L4) — `project_dir` is
  no longer required. New `subscribe/2` arity takes keyword options
  only; `subscribe/3` stays for backward compatibility with the old
  positional signature.
- **`ExAtlas.Fly.Tokens.AppServer` config resolution** (M8, M9) —
  `:fly_config_file_enabled` and `:cli_timeout_ms` are now resolved
  once at AppServer `init/1` rather than on every `handle_call`. Uses
  the consistent `Keyword.get(config, :key, default)` pattern.
- **`ExAtlas.Fly.Tokens.AppServer` structured logging** (E4) —
  remaining `Logger.warning` interpolations for CLI failures now use
  metadata (`app:`, `exit_code:`, `output:`, `timeout_ms:`) instead of
  interpolated strings.
- **`ExAtlas.Fly.TokenStorage.Dets` mkdir fallback** (M6) — when the
  explicitly-configured `:storage_path` is not writable, falls back to
  `System.tmp_dir!/0` with a `:warning` log, rather than crashing on
  `File.mkdir_p!/1`. Previously only the default path had the fallback.
- **`unless` → `if` throughout `deploy.ex`** (L1).
- **`deploy/2` and `stream_deploy/3` error shape typed explicitly**
  (L2) — new `ExAtlas.Fly.Deploy.deploy_error/0` type spec documents
  the three `:fly_error` reason variants (`:not_found`, `:timeout`,
  `non_neg_integer()`).

### Installer

- **`mix ex_atlas.install` runtime.exs example** (M2) — the post-install
  notice now includes a `runtime.exs` pattern for containerized deploys
  that want to override `:storage_path` via an environment variable.

### Dispatcher docs (H7)

- Added a subsection describing dispatch serialization semantics and
  pointing hosts with large fan-out at `:phoenix_pubsub` mode. The
  per-subscriber `send/2` loop in `:registry` mode is documented as
  intentional for the typical log-streaming / deploy workload.

## v0.4.1 — unreleased

### Changed — Async token persist (closes audit H3)

- `ExAtlas.Fly.Tokens.AppServer` now offloads cached-token storage
  writes to a supervised `Task` under a new
  `ExAtlas.Fly.Tokens.TaskSupervisor` child. The AppServer's
  `handle_call` replies as soon as ETS is updated; `:dets.sync`
  happens in the background.
- Net effect: a slow storage write for one app no longer blocks that
  app's own subsequent token requests (and never blocked other apps',
  post-E1). Callers get the token with latency gated on ETS + cmd_fn
  only. Audit finding H3.
- **Manual-token persist stays synchronous.** Manual tokens are not
  re-acquirable, so `ExAtlas.Fly.Tokens.set_manual/2` still returns
  `{:error, {:persist_failed, reason}}` when storage raises — the
  caller must know if persist failed.
- Persist failures on the cached path continue to log at `:error`
  level with `{app, reason}` metadata, now emitted from the task
  rather than the mailbox (contract preserved, emission point
  moved).

### Added

- `ExAtlas.Fly.Tokens.TaskSupervisor` is a new child of
  `ExAtlas.Fly.Tokens.Supervisor`, ordered after `ETSOwner` and
  before the `DynamicSupervisor`. Tests can inject a custom name
  via `:task_sup` on `Tokens.Supervisor.start_link/1`.

## v0.4.0 — unreleased

### Changed — Per-app Fly tokens (audit E1; closes H3, H4)

- Replaced the singleton `ExAtlas.Fly.Tokens.Server` with a per-app
  `ExAtlas.Fly.Tokens.AppServer` supervised under
  `ExAtlas.Fly.Tokens.Supervisor`. Token resolution for one app no
  longer blocks resolution for any other. A thundering herd of CLI
  acquisitions (e.g. post-VM-restart across N apps) now runs in
  parallel rather than serialized behind a single mailbox.
- `ExAtlas.Fly.Tokens.Server` is **removed**. The documented public API
  (`ExAtlas.Fly.Tokens.{get/1, invalidate/1, set_manual/2}`) is
  unchanged and remains the stable entry point.
- Shared ETS table (`:ex_atlas_fly_tokens`) is now `:public` and owned
  by `ExAtlas.Fly.Tokens.ETSOwner`, outliving individual AppServer
  crashes. A crashed AppServer restarts with its cache intact; an
  ETSOwner crash rebuilds the whole tokens subtree via `:rest_for_one`
  (Registry survives, DynamicSupervisor + every AppServer restart).
- Concurrent `Tokens.get/1` calls for the **same** app coalesce at the
  AppServer mailbox — only the first-in-line caller invokes the CLI;
  subsequent callers re-check ETS (filled by the first) before
  descending the resolution chain.

### Added

- `[:ex_atlas, :fly, :token, :acquire]` `:stop` metadata gains a new
  `:acquirer` field — `:facade` for pure ETS fast-path hits (no
  AppServer consulted) or `:app_server` for slow-path / coalesced
  resolutions. Existing handlers that match only on `:source` are
  unaffected. See `guides/telemetry.md` for the diagnostic interpretation.
- `ExAtlas.Fly.Tokens.Supervisor.whereis_app_server/2` and
  `resolve_app_server/2` — lookup / resolve-or-start helpers.
  Primarily for tests.

## v0.3.1 — 2026-04-22

### Added — Telemetry for Fly platform ops

- `[:ex_atlas, :fly, :token, :acquire]` span events around every
  `ExAtlas.Fly.Tokens.get/1` call. `:stop` metadata includes `source:`
  (`:ets` / `:storage` / `:config` / `:cli` / `:manual` / `:none`) so
  operators can measure cache-hit rate and acquisition-path latency.
- `[:ex_atlas, :fly, :logs, :fetch]` span events around
  `ExAtlas.Fly.Logs.Client.fetch_logs/3`. Metadata: `{app, status, count}`.
  Inherited automatically by `fetch_logs_with_retry/2`.
- `[:ex_atlas, :fly, :deploy, :line]` (one per non-empty output line) +
  `[:ex_atlas, :fly, :deploy, :exit]` (one per deploy termination) from
  `Deploy.stream_deploy/3`. Line content is deliberately excluded — Fly
  build output can contain bearer tokens.

See `guides/telemetry.md` for the full event reference.

### Added — Shared TokenStorage conformance suite

- `ExAtlas.Fly.TokenStorageConformance` — a `use`-able ExUnit macro that
  any `TokenStorage` implementation can adopt to inherit the full
  `get/put/delete` contract coverage across `:cached` and `:manual`
  keys. Mirrors the existing `ExAtlas.Test.ProviderConformance` pattern.
- `Memory` and `Dets` both run under the shared suite now, so any
  future adapter (Redis, Postgres, vault) can prove parity with one
  `use` line.

## v0.3.0 — unreleased

### Changed — Fly token / streamer return contracts

- `ExAtlas.Fly.Tokens.set_manual/2` (and `Tokens.Server.set_manual_token/3`)
  now return `:ok | {:error, {:persist_failed, reason}}` instead of always
  `:ok`. Manual tokens are not re-acquirable, so storage failures must be
  surfaced rather than silently logged. Callers that pattern-match on
  `:ok` should handle the error tuple.
- `ExAtlas.Fly.subscribe_logs/3` (and `Streamer.subscribe/3`) now return
  `:ok | {:error, :no_streamer}` when no streamer can be resolved
  (e.g. the Fly sub-tree is disabled). Previously this case returned a
  silent `:ok` with no messages ever arriving.

### Fixed — Hardening round

- `ExAtlas.Fly.Tokens.Server` `persist/3` (cached path) now returns
  `:ok | {:error, {:persist_failed, reason}}` and logs failures at
  `:error` level with `{app, reason}` metadata instead of `:warning`
  with interpolated strings. ETS still holds a fresh token for the
  session, but a silent storage outage is now operator-visible.
- `ExAtlas.Fly.Dispatcher` `:mfa` mode wraps the host MFA in
  `try/rescue/catch` so a raising MFA no longer takes down the caller
  (most commonly the log Streamer, whose crash drops the pagination
  cursor). Failures are logged at `:error` level with the topic and MFA
  identity.
- `ExAtlas.Fly.TokenStorage.Dets` refuses to auto-recreate a corrupt
  `manual.dets` file on startup — manual tokens are bearer credentials
  that are NOT re-acquirable. Returns `{:stop, {:manual_dets_corrupt,
  path, reason}}` and preserves the file for operator intervention. The
  cached-token path still recreates (re-acquirable, perf regression only).
- `ExAtlas.Fly.TokenStorage.Dets` now `chmod`s the storage dir to `0700`
  and each DETS file to `0600` after open. Default umask on typical
  Linux/macOS left token files world- or group-readable.
- `mix ex_atlas.install` surfaces `.gitignore` update failures as an
  `Igniter.add_notice` with the exact line the user must add manually;
  previously the installer silently swallowed the exception and moved on.
- `ExAtlas.Fly.TokenStorage.Memory` (test support) now catches `:exit`
  from pre-init reads and returns `:error`, matching the Dets `rescue
  ArgumentError` semantics so the test double is faithful to prod.

### Added

- `ExAtlas.Fly.TokenStorage.Dets.start_link/1` accepts `:name`,
  `:cached_table`, `:manual_table` opts so custom-supervised /
  per-test instances are possible alongside the default singleton.
- First test coverage for `ExAtlas.Fly.Dispatcher`, `TokenStorage.Dets`,
  `TokenStorage.Memory`, and the `Streamer.subscribe/3` silent-failure
  path.

## v0.2.0 — unreleased

### Fixed

- `ExAtlas.Fly.Logs.Client.next_start_time/1` no longer crashes the
  Streamer when a log entry has a `nil` or malformed ISO-8601 timestamp;
  unparseable entries are logged and skipped.
- `ExAtlas.Fly.Deploy.stream_deploy/3` cleans both the activity and
  absolute timers symmetrically across all exit branches, so no stray
  `{:deploy_*_timeout, _}` message leaks into a long-lived caller's
  mailbox. Exposes `:activity_timeout_ms` / `:max_timeout_ms` options.
- `ExAtlas.Fly.Tokens.Server` now implements `terminate/2` to delete its
  named ETS table, avoiding an `ArgumentError` on supervisor restart,
  and defensively reclaims an existing table in `init/1`.
- `ExAtlas.Fly.Tokens.Server` shuts down a hung `fly` CLI task with
  `:brutal_kill` so the configured `cli_timeout_ms` is actually the
  mailbox blocking time, not `cli_timeout_ms + 5_000`.
- `ExAtlas.Fly.Logs.StreamerSupervisor` uses `:rest_for_one` with a
  generous restart budget on the `DynamicSupervisor` so one app's
  misbehaving streamer no longer tears down the registry and every
  other app's pagination cursor.

### Added — Fly.io platform operations

- `ExAtlas.Fly` top-level facade for Fly.io platform ops:
  `discover_apps/1`, `deploy/2`, `stream_deploy/3`, `subscribe_logs/3`,
  `unsubscribe_logs/1`, `subscribe_deploy/1`, `unsubscribe_deploy/1`.
- `ExAtlas.Fly.Deploy` — `fly deploy --remote-only` with 15 min timeout
  (`deploy/2`) and Port-based streaming (`stream_deploy/3`) with a
  5 min activity timer and 30 min absolute cap. Dispatches
  `{:ex_atlas_fly_deploy, ticket_id, line}` on each line.
- `ExAtlas.Fly.Logs.Client` — `Req`-backed client for the Fly Machines
  log API (NDJSON, cursor pagination, automatic 401 retry).
- `ExAtlas.Fly.Logs.Streamer` + `StreamerSupervisor` — per-app GenServer
  that polls the log API every 2 s, dispatches
  `{:ex_atlas_fly_logs, app, entries}`, and stops once all subscribers
  have disconnected (monitor-based).
- `ExAtlas.Fly.Tokens` + `ExAtlas.Fly.Tokens.Server` — cache-first token
  resolver. Order: ETS → `TokenStorage` → `~/.fly/config.yml` →
  `fly tokens create readonly` → manual override.
- `ExAtlas.Fly.TokenStorage` — pluggable behaviour for durable token
  persistence. Default impl `ExAtlas.Fly.TokenStorage.Dets` is
  zero-config and survives VM restarts.
- `ExAtlas.Fly.Dispatcher` — framework-agnostic broadcast. Modes:
  `:registry` (default, zero-dep), `:phoenix_pubsub` (when host uses
  Phoenix), or `{:mfa, {m, f, a}}` custom routing.
- `ExAtlas.Application` now supervises the Fly sub-tree by default.
  Disable with `config :ex_atlas, :fly, enabled: false`.

### Added — Igniter installer

- `mix ex_atlas.install` — adds sensible `config :ex_atlas, :fly` defaults,
  creates the DETS storage directory, wires `phoenix_pubsub` when
  available.
- `mix ex_atlas.upgrade` — runs per-version upgraders (no-op for 0.1.x
  → 0.2.0; reserved for future migrations).

### Changed

- Description and package scope broadened from "GPU/compute SDK" to
  "infrastructure SDK".
- `ExAtlas.Application`'s Fly sub-tree boots by default. The existing
  orchestrator sub-tree is still opt-in via `start_orchestrator: true`.

## v0.1.0 — unreleased

Initial public release.

### Added — Core API

- `ExAtlas` top-level provider-agnostic module (`spawn_compute/1`,
  `get_compute/2`, `list_compute/1`, `stop/2`, `start/2`, `terminate/2`,
  `run_job/1`, `get_job/2`, `cancel_job/2`, `stream_job/2`,
  `list_gpu_types/1`, `capabilities/1`).
- `ExAtlas.Provider` behaviour defining the contract every provider
  implements.
- `ExAtlas.Config` — per-call > app-env > env-var resolution for provider
  and API key. Supports user-defined provider modules passed directly by
  name (no registration needed).
- `ExAtlas.Error` — canonical error struct with `:kind` atoms
  (`:unauthorized`, `:not_found`, `:rate_limited`, `:timeout`,
  `:unsupported`, `:validation`, `:provider`, `:transport`, `:unknown`)
  and `from_response/3` for translating HTTP responses.

### Added — Normalized specs

- `ExAtlas.Spec.ComputeRequest` — input to `spawn_compute/1` with
  `NimbleOptions`-validated fields, `:provider_opts` escape hatch.
- `ExAtlas.Spec.Compute` — normalized compute resource response.
- `ExAtlas.Spec.JobRequest` / `ExAtlas.Spec.Job` — serverless jobs.
- `ExAtlas.Spec.GpuType` — catalog entry with pricing + stock.
- `ExAtlas.Spec.GpuCatalog` — stable canonical GPU atoms
  (`:h100`, `:a100_80g`, `:rtx_4090`, ...) mapped to each provider's
  native identifier.

### Added — Providers

- `ExAtlas.Providers.RunPod` — full implementation covering REST management
  (pods, endpoints, templates, network volumes, billing), serverless
  runtime (async/sync/stream job submission, status, cancel), and the
  legacy GraphQL pricing catalog. Built on `Req`.
  - Sub-modules: `Client`, `GraphQL`, `Pods`, `Endpoints`, `Jobs`,
    `Templates`, `NetworkVolumes`, `Billing`, `Translate`.
- `ExAtlas.Providers.Mock` — in-memory ETS-backed provider for tests and
  demos. Implements every callback.
- `ExAtlas.Providers.Stub` macro — shared base for placeholder providers.
- `ExAtlas.Providers.Fly`, `ExAtlas.Providers.LambdaLabs`,
  `ExAtlas.Providers.Vast` — placeholder modules reserving atoms and
  capability lists for v0.2 / v0.3.

### Added — Auth

- `ExAtlas.Auth.Token` — cryptographically random 256-bit bearer tokens
  with SHA-256 hashing and constant-time comparison (`Plug.Crypto`).
- `ExAtlas.Auth.SignedUrl` — S3-style HMAC-SHA256 signed URLs with
  expiry, for media streams and WebSockets that can't set headers.
- Auto-injection: `auth: :bearer` on `spawn_compute/1` mints a token,
  injects it into the pod as `ATLAS_PRESHARED_KEY`, and returns the
  handle in `compute.auth`.

### Added — Orchestrator (opt-in)

- `ExAtlas.Orchestrator` — high-level API (`spawn/1`, `touch/1`, `info/1`,
  `stop_tracked/1`, `list_ids/0`).
- `ExAtlas.Orchestrator.ComputeServer` — one GenServer per tracked
  resource, traps exits, enforces `:idle_ttl_ms`, broadcasts state
  changes via `ExAtlas.Orchestrator.Events`.
- `ExAtlas.Orchestrator.ComputeSupervisor` (`DynamicSupervisor`) +
  `ExAtlas.Orchestrator.ComputeRegistry` (`Registry` with `:via` lookup).
- `ExAtlas.Orchestrator.Reaper` — periodic reconciliation; terminates
  orphans whose `:name` matches the configurable safety-prefix.
- `ExAtlas.Application` starts the tree only when
  `config :ex_atlas, start_orchestrator: true`; library-only users pay
  nothing.
- Phoenix.PubSub broadcasts on `"compute:<id>"` topic as
  `{:atlas_compute, id, event}` for `{:status, s}`,
  `{:heartbeat, ms}`, `{:terminating, reason}`,
  `{:terminate_failed, err}` events.

### Added — Phoenix LiveDashboard integration

- `ExAtlas.LiveDashboard.ComputePage` — drop-in
  `Phoenix.LiveDashboard.PageBuilder` page. Host apps mount it via
  `additional_pages: [atlas: ExAtlas.LiveDashboard.ComputePage]`. Live
  table with Touch/Stop/Terminate row actions. Auto-refreshing;
  subscribes to `ExAtlas.PubSub` for push updates when available.
- Guarded by `Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)` so
  the module only compiles when LiveDashboard is in the host app's deps.

### Added — HTTP + observability

- Every REST / runtime / GraphQL request goes through `Req` with
  `:retry :transient`, 3 retries by default, and telemetry.
- Telemetry events `[:ex_atlas, <provider>, :request]` with
  `%{status: status}` measurements and `%{api, method, url}` metadata.
- Per-call `Req` overrides via `req_options:`.

### Added — Testing

- `ExAtlas.Test.ProviderConformance` — shared ExUnit suite every provider
  implementation must pass. `use`-macro form accepts `:reset` MFA for
  test isolation.
- Full unit coverage (68 tests, 3 doctests).

### Added — Documentation

- Comprehensive `README.md` with architecture diagram, capability
  matrix, GPU mapping table, error kinds, security considerations,
  FAQ, and roadmap.
- `guides/getting_started.md`, `guides/transient_pods.md`,
  `guides/writing_a_provider.md`, `guides/telemetry.md`,
  `guides/testing.md` — long-form deep-dives surfaced via ex_doc extras.
- Full module-level `@moduledoc` on every public module.
