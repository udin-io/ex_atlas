# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAtlas adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.2.0-dev — unreleased

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
