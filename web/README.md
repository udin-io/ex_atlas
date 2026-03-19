# Atlas

Unified SRE/DevOps infrastructure management tool for Udin. Atlas provides a single pane of glass across cloud providers (Fly.io, RunPod), with real-time monitoring, interactive topology visualization, and health alerting.

## Product Overview

Atlas solves the problem of infrastructure sprawl: Udin's services run across multiple cloud providers with no unified way to see what's running, what's healthy, and what needs attention. Atlas connects to each provider's API, syncs resource state into a local data model, and presents it through a real-time LiveView dashboard.

### Core Capabilities

- **Multi-provider inventory** — Sync apps, machines, volumes, and storage buckets from Fly.io and RunPod into a canonical data model
- **Real-time dashboard** — Live counts of providers, apps, machines, and active alerts with severity indicators
- **Interactive topology graph** — D3.js force-directed visualization of infrastructure relationships (apps → machines → volumes) with status-based coloring and click-to-navigate
- **Health monitoring** — Automated health checks every 5 minutes via Oban cron, with alert creation for degraded/unhealthy/unreachable machines
- **Alert management** — View, acknowledge, and resolve alerts by severity (info/warning/critical)
- **Provider credential management** — Add, test, enable/disable, and configure sync intervals per provider
- **Encrypted secrets** — API tokens encrypted at rest via AshCloak (AES-GCM)
- **Extensible provider architecture** — Behaviour-based adapter pattern; add new providers without touching core sync logic

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Elixir |
| Web framework | Phoenix 1.8 + LiveView 1.1 |
| Domain framework | Ash 3.0 + AshPostgres |
| Authentication | AshAuthentication (email/password, magic link, email confirmation) |
| State machines | AshStateMachine |
| Background jobs | Oban 2.0 (with Oban Web dashboard) |
| Encryption | AshCloak + Cloak (AES-GCM vault) |
| HTTP client | Req |
| Email | Swoosh |
| CSS | Tailwind + DaisyUI |
| JS bundler | esbuild |
| Visualization | D3.js (force-directed graph) |
| Database | PostgreSQL |
| Deployment | Fly.io |

## Data Model

### Accounts
- **User** — Email/password auth with confirmation, password reset, magic link, remember-me tokens
- **Token** — JWT session tokens

### Providers
- **Credential** — Stores encrypted API tokens per provider (Fly.io, RunPod) with sync status, health, and configurable sync interval

### Infrastructure
- **App** — Cloud application with state machine: `pending → deployed → suspended → error → destroyed`
- **Machine** — VM instance with state machine: `created → started → stopped → suspended → error → destroyed`. Tracks CPU kind, CPU count, memory, GPU type, IP addresses, region, image
- **Volume** — Attached storage: size, region, status, provider ID
- **StorageBucket** — Cloud storage resources

### Monitoring
- **Alert** — Severity (`info`, `warning`, `critical`), status (`firing`, `acknowledged`, `resolved`), tracks metric name, threshold, actual value
- **HealthCheck** — Periodic results: status (`healthy`, `degraded`, `unhealthy`, `unreachable`), response time, check details
- **MetricSnapshot** — Historical metric data

## Pages & Features

| Route | Page | Description |
|-------|------|-------------|
| `/dashboard` | Dashboard | Real-time overview: provider/app/machine counts, running machines, active alerts |
| `/providers` | Providers | List all configured cloud providers with status and sync indicators |
| `/providers/new` | New Provider | Add a new cloud provider credential |
| `/providers/:id` | Provider Detail | View provider details, machines, and sync status |
| `/providers/:id/edit` | Edit Provider | Update credentials and sync configuration |
| `/infrastructure` | Infrastructure | Searchable/filterable list of apps by provider, status, and text search |
| `/infrastructure/apps/:id` | App Detail | App info with associated machines |
| `/infrastructure/machines/:id` | Machine Detail | Machine specs, status, and health check history |
| `/topology` | Topology | Interactive D3.js graph: drag nodes, zoom, click to navigate to detail views |

## Provider Adapters

### Fly.io
- HTTP client for the Machines API (v1)
- Syncs apps, machines, and volumes
- Normalizes Fly states to canonical Atlas states
- Start/stop machine actions

### RunPod
- HTTP client for RunPod REST API (v1)
- Syncs pods and network volumes
- Normalizes RunPod responses to canonical format

### Adding a New Provider
1. Create an adapter module implementing `Atlas.Providers.Adapter` behaviour
2. Implement a client module for the provider's API
3. Implement a normalizer to map provider responses to the canonical schema
4. Add the provider type to the `Credential` resource's provider enum
5. The `DynamicSupervisor` + `SyncWorker` infrastructure handles the rest

## Background Jobs

- **HealthCheckCronWorker** — Runs every 5 minutes, enqueues health checks for all sync-enabled credentials
- **HealthCheckWorker** — Checks machine health per credential, records response time, creates alerts for degraded states
- **SyncWorker** — Per-credential worker spawned on boot/credential creation, periodically syncs apps, machines, and volumes from cloud providers

## What's Completed

- [x] Phoenix + Ash project scaffold with PostgreSQL
- [x] Authentication (email/password, magic link, email confirmation, password reset)
- [x] Seed data with admin user (`admin@dev.local`)
- [x] Cloud provider credential management (CRUD, test connection, enable/disable sync)
- [x] API token encryption at rest (AshCloak)
- [x] Fly.io adapter (client, normalizer, sync)
- [x] RunPod adapter (client, normalizer, sync)
- [x] Infrastructure data model with state machines (App, Machine, Volume)
- [x] Dashboard with real-time stats and active alerts
- [x] Infrastructure list view with search and filtering
- [x] App and Machine detail views
- [x] Interactive topology visualization (D3.js)
- [x] Health check system (Oban cron, per-machine checks, alert creation)
- [x] Alert management (view, acknowledge, resolve)
- [x] PubSub real-time updates across all views
- [x] Configurable port via `ATLAS_PORT` env var (for Udincode orchestration)
- [x] DaisyUI component system with semantic colors
- [x] Fly.io deployment configuration

## What's Missing / Planned

- [ ] **Node management actions** — Upgrade, provision, restart, destroy machines from Atlas UI
- [ ] **Backup management** — Trigger, schedule, and monitor volume/database backups
- [ ] **Grafana/Prometheus integration** — Pull real metrics into MetricSnapshot, display charts/dashboards
- [ ] **Metric visualization** — Time-series charts for CPU, memory, network, GPU utilization
- [ ] **Cost tracking** — Per-provider and per-resource cost breakdown
- [ ] **Multi-user / RBAC** — Role-based access control (admin, viewer, operator)
- [ ] **Audit log** — Track who did what and when
- [ ] **Notification channels** — Slack, email, PagerDuty for alert routing
- [ ] **Additional providers** — AWS, GCP, Hetzner, or other providers Udin expands to
- [ ] **Scheduled maintenance windows** — Suppress alerts during planned work
- [ ] **API / CLI** — JSON API for external tooling and a CLI for automation
- [ ] **Test coverage** — Comprehensive test suite for adapters, workers, and LiveView

## Development

### Prerequisites

- Elixir 1.17+
- PostgreSQL 15+
- Node.js (for esbuild/tailwind assets)

### Setup

```bash
cd web
mix setup          # Install deps, create DB, run migrations, seed data
mix phx.server     # Start at http://localhost:4000
```

### Default Credentials

- Email: `admin@dev.local`
- Password: `Testpass!23`

### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `ATLAS_PORT` | Server port (highest priority) | — |
| `PORT` | Server port (Fly.io convention) | `4000` |
| `DATABASE_URL` | PostgreSQL connection string | dev config |
| `SECRET_KEY_BASE` | Session/cookie signing | dev config |
| `TOKEN_SIGNING_SECRET` | JWT signing | dev config |
| `CLOAK_KEY` | AES-GCM encryption key for API tokens | dev config |
| `PHX_HOST` | Public hostname (production) | `localhost` |

### Useful Commands

```bash
mix ash.codegen <name>     # Generate migrations from Ash resource changes
mix ash.migrate            # Run migrations
mix format                 # Format code
mix test                   # Run tests
```

### Dev Tools

- **Ash Admin** — Available in dev at `/admin`
- **Oban Web** — Job queue dashboard
- **Phoenix Live Dashboard** — Metrics at `/dev/dashboard`
- **Dev Mailbox** — Sent emails at `/dev/mailbox`

## Architecture Decision Records

- [ADR-0001: Seed Data Admin User Confirmation](adr/0001-seed-data-admin-user-confirmation.md)
- [ADR-0002: Atlas Port Environment Variable](adr/0002-atlas-port-env-var.md)
