# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAtlas adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
