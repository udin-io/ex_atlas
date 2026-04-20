# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and Atlas adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0 — unreleased

Initial public release.

### Added — Core API

- `Atlas` top-level provider-agnostic module (`spawn_compute/1`,
  `get_compute/2`, `list_compute/1`, `stop/2`, `start/2`, `terminate/2`,
  `run_job/1`, `get_job/2`, `cancel_job/2`, `stream_job/2`,
  `list_gpu_types/1`, `capabilities/1`).
- `Atlas.Provider` behaviour defining the contract every provider
  implements.
- `Atlas.Config` — per-call > app-env > env-var resolution for provider
  and API key. Supports user-defined provider modules passed directly by
  name (no registration needed).
- `Atlas.Error` — canonical error struct with `:kind` atoms
  (`:unauthorized`, `:not_found`, `:rate_limited`, `:timeout`,
  `:unsupported`, `:validation`, `:provider`, `:transport`, `:unknown`)
  and `from_response/3` for translating HTTP responses.

### Added — Normalized specs

- `Atlas.Spec.ComputeRequest` — input to `spawn_compute/1` with
  `NimbleOptions`-validated fields, `:provider_opts` escape hatch.
- `Atlas.Spec.Compute` — normalized compute resource response.
- `Atlas.Spec.JobRequest` / `Atlas.Spec.Job` — serverless jobs.
- `Atlas.Spec.GpuType` — catalog entry with pricing + stock.
- `Atlas.Spec.GpuCatalog` — stable canonical GPU atoms
  (`:h100`, `:a100_80g`, `:rtx_4090`, ...) mapped to each provider's
  native identifier.

### Added — Providers

- `Atlas.Providers.RunPod` — full implementation covering REST management
  (pods, endpoints, templates, network volumes, billing), serverless
  runtime (async/sync/stream job submission, status, cancel), and the
  legacy GraphQL pricing catalog. Built on `Req`.
  - Sub-modules: `Client`, `GraphQL`, `Pods`, `Endpoints`, `Jobs`,
    `Templates`, `NetworkVolumes`, `Billing`, `Translate`.
- `Atlas.Providers.Mock` — in-memory ETS-backed provider for tests and
  demos. Implements every callback.
- `Atlas.Providers.Stub` macro — shared base for placeholder providers.
- `Atlas.Providers.Fly`, `Atlas.Providers.LambdaLabs`,
  `Atlas.Providers.Vast` — placeholder modules reserving atoms and
  capability lists for v0.2 / v0.3.

### Added — Auth

- `Atlas.Auth.Token` — cryptographically random 256-bit bearer tokens
  with SHA-256 hashing and constant-time comparison (`Plug.Crypto`).
- `Atlas.Auth.SignedUrl` — S3-style HMAC-SHA256 signed URLs with
  expiry, for media streams and WebSockets that can't set headers.
- Auto-injection: `auth: :bearer` on `spawn_compute/1` mints a token,
  injects it into the pod as `ATLAS_PRESHARED_KEY`, and returns the
  handle in `compute.auth`.

### Added — Orchestrator (opt-in)

- `Atlas.Orchestrator` — high-level API (`spawn/1`, `touch/1`, `info/1`,
  `stop_tracked/1`, `list_ids/0`).
- `Atlas.Orchestrator.ComputeServer` — one GenServer per tracked
  resource, traps exits, enforces `:idle_ttl_ms`, broadcasts state
  changes via `Atlas.Orchestrator.Events`.
- `Atlas.Orchestrator.ComputeSupervisor` (`DynamicSupervisor`) +
  `Atlas.Orchestrator.ComputeRegistry` (`Registry` with `:via` lookup).
- `Atlas.Orchestrator.Reaper` — periodic reconciliation; terminates
  orphans whose `:name` matches the configurable safety-prefix.
- `Atlas.Application` starts the tree only when
  `config :atlas, start_orchestrator: true`; library-only users pay
  nothing.
- Phoenix.PubSub broadcasts on `"compute:<id>"` topic as
  `{:atlas_compute, id, event}` for `{:status, s}`,
  `{:heartbeat, ms}`, `{:terminating, reason}`,
  `{:terminate_failed, err}` events.

### Added — Phoenix LiveDashboard integration

- `Atlas.LiveDashboard.ComputePage` — drop-in
  `Phoenix.LiveDashboard.PageBuilder` page. Host apps mount it via
  `additional_pages: [atlas: Atlas.LiveDashboard.ComputePage]`. Live
  table with Touch/Stop/Terminate row actions. Auto-refreshing;
  subscribes to `Atlas.PubSub` for push updates when available.
- Guarded by `Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)` so
  the module only compiles when LiveDashboard is in the host app's deps.

### Added — HTTP + observability

- Every REST / runtime / GraphQL request goes through `Req` with
  `:retry :transient`, 3 retries by default, and telemetry.
- Telemetry events `[:atlas, <provider>, :request]` with
  `%{status: status}` measurements and `%{api, method, url}` metadata.
- Per-call `Req` overrides via `req_options:`.

### Added — Testing

- `Atlas.Test.ProviderConformance` — shared ExUnit suite every provider
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
