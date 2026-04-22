# ExAtlas

[![Hex.pm](https://img.shields.io/hexpm/v/atlas.svg)](https://hex.pm/packages/atlas)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/atlas)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)

A composable, pluggable Elixir SDK for **infrastructure management**.
Two concerns under one roof:

1. **GPU / CPU compute across cloud providers.** Spawn pods, run serverless
   inference, orchestrate transient per-user GPU sessions. Swap providers by
   changing one option.
2. **Fly.io platform operations.** First-class deploys, log streaming, and
   token lifecycle — independent of the compute pipeline. See
   [`ExAtlas.Fly`](lib/atlas/fly.ex) and the [Fly guide](guides/fly.md).

- **One contract, many providers.** `ExAtlas.Provider` is a behaviour; swap
  `:runpod`, `:fly`, `:lambda_labs`, `:vast`, or your own module without
  changing call sites.
- **Fly.io platform ops.** `ExAtlas.Fly.*` handles `fly deploy` streaming,
  log tailing, and the full token resolution chain
  (ETS → DETS → `~/.fly/config.yml` → `fly tokens create`). Works without
  Phoenix.
- **Batteries-included orchestration.** `Registry` + `DynamicSupervisor`
  + `Phoenix.PubSub` + reaper for the "per-user transient pod" pattern.
- **Igniter installer.** `mix igniter.install ex_atlas` wires everything up.
- **Built for the S3-style handoff.** `ExAtlas.Auth` mints bearer tokens and
  S3-style HMAC-signed URLs so your browser can talk directly to a pod without
  the Phoenix app proxying every frame.
- **Pure `Req` under the hood.** Every HTTP call goes through
  [Req](https://hex.pm/packages/req), so you get retries, decoding, and
  telemetry for free.
- **LiveDashboard included.** Drop `ExAtlas.LiveDashboard.ComputePage` into
  your existing dashboard and get a live ops view of every tracked pod.

---

## Table of contents

- [Installation](#installation)
- [Architecture at a glance](#architecture-at-a-glance)
- [Quick start — Fly.io platform ops](#quick-start--flyio-platform-ops)
- [Quick start — transient per-user GPU pod](#quick-start--transient-per-user-gpu-pod)
- [Quick start — serverless inference](#quick-start--serverless-inference)
- [Swapping providers](#swapping-providers)
- [Configuration](#configuration)
- [Providers](#providers)
- [The `ExAtlas.Provider` behaviour](#the-atlasprovider-behaviour)
- [Normalized specs (`ExAtlas.Spec.*`)](#normalized-specs-atlasspec)
- [Auth primitives](#auth-primitives)
- [Orchestrator — lifecycle, events, reaper](#orchestrator--lifecycle-events-reaper)
- [Phoenix LiveDashboard integration](#phoenix-livedashboard-integration)
- [HTTP layer + telemetry](#http-layer--telemetry)
- [Error handling](#error-handling)
- [Writing your own provider](#writing-your-own-provider)
- [Testing](#testing)
- [Security considerations](#security-considerations)
- [Troubleshooting & FAQ](#troubleshooting--faq)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Installation

The one-liner — uses the [Igniter](https://hex.pm/packages/igniter) installer
to add the dep, write sensible config, and create storage directories:

```bash
mix igniter.install ex_atlas
```

Or add manually to `mix.exs`:

```elixir
def deps do
  [
    {:ex_atlas, "~> 0.2"}
  ]
end
```

…then run `mix ex_atlas.install` once to wire config defaults, or configure
things yourself (see [Configuration](#configuration)).

For the optional orchestrator + LiveDashboard features, also include:

```elixir
{:phoenix_pubsub, "~> 2.1"},           # PubSub broadcasts from the orchestrator
{:phoenix_live_dashboard, "~> 0.8"}    # ExAtlas.LiveDashboard.ComputePage tab
```

ExAtlas declares both as `optional: true`, so they are not pulled into pure
library consumers.

### Upgrading

To upgrade atlas and run any version-specific migrations:

```bash
mix deps.update atlas
mix ex_atlas.upgrade
```

The upgrade task is idempotent and runs only the steps needed between your
previous and current atlas version.

## Architecture at a glance

```
┌───────────────────────────────────────────────────────────────────────┐
│  ExAtlas (top-level provider-agnostic API)                              │
│  ExAtlas.spawn_compute/1 · run_job/2 · stream_job/1 · terminate/1       │
└───────────────────────────┬───────────────────────────────────────────┘
                            │
            ┌───────────────▼───────────────┐    ┌───────────────────┐
            │  ExAtlas.Provider (behaviour)   │◄───│  ExAtlas.Spec.*     │
            └───────────────┬───────────────┘    │  normalized structs│
                            │                    └───────────────────┘
    ┌─────────┬─────────────┼──────────────┬─────────────┐
    │         │             │              │             │
 ┌──▼───┐ ┌──▼───┐ ┌───────▼────────┐ ┌──▼─────┐ ┌──────▼──────┐
 │RunPod│ │ Fly  │ │  Lambda Labs   │ │ Vast   │ │  Mock (test)│
 │ v0.1 │ │ v0.2 │ │     v0.2       │ │ v0.3   │ │    v0.1     │
 └──────┘ └──────┘ └────────────────┘ └────────┘ └─────────────┘

┌───────────────────────────────────────────────────────────────────────┐
│  ExAtlas.Orchestrator (opt-in supervision tree)                         │
│  ComputeServer (GenServer/resource) · Registry · DynamicSupervisor    │
│  · Reaper · PubSub events                                             │
└───────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────┐
│  ExAtlas.Auth                                                           │
│  Token (bearer mint/verify) · SignedUrl (S3-style HMAC)               │
└───────────────────────────────────────────────────────────────────────┘

┌───────────────────────────────────────────────────────────────────────┐
│  ExAtlas.LiveDashboard.ComputePage                                      │
│  Live-refreshing table · per-row Touch/Stop/Terminate                 │
└───────────────────────────────────────────────────────────────────────┘
```

## Quick start — Fly.io platform ops

ExAtlas gives you a clean Elixir API over `fly deploy`, the Fly Machines log API,
and Fly token lifecycle. Works with or without Phoenix.

### Discover apps

```elixir
ExAtlas.Fly.discover_apps("/path/to/project")
# => [{"my-api", "/path/to/project"}, {"my-web", "/path/to/project/web"}]
```

### Tail logs

```elixir
ExAtlas.Fly.subscribe_logs("my-api", "/path/to/project")

# In the subscriber:
def handle_info({:ex_atlas_fly_logs, "my-api", entries}, state) do
  # entries :: [ExAtlas.Fly.Logs.LogEntry.t()]
  ...
end
```

A single streamer runs per app regardless of subscriber count, and stops once
all subscribers disconnect. Automatic 401 retry is built in.

### Stream a deploy

```elixir
ExAtlas.Fly.subscribe_deploy(ticket_id)
Task.start(fn ->
  ExAtlas.Fly.stream_deploy(project_path, "web", ticket_id)
end)

def handle_info({:ex_atlas_fly_deploy, ^ticket_id, line}, state) do
  ...
end
```

Deploys are guarded by a 5 min activity timer (resets on output) and a 30 min
absolute cap.

### Tokens

`ExAtlas.Fly.Tokens` resolves tokens via ETS → DETS (durable) → `~/.fly/config.yml`
→ `fly tokens create readonly` → manual override. You usually don't call it
directly — the log client uses it transparently — but you can:

```elixir
{:ok, token} = ExAtlas.Fly.Tokens.get("my-api")
ExAtlas.Fly.Tokens.invalidate("my-api")
ExAtlas.Fly.Tokens.set_manual("my-api", "fo1_...")
```

Full docs: [Fly guide](guides/fly.md).

## Quick start — transient per-user GPU pod

The motivating use case: a Fly.io-hosted Phoenix app spawns a RunPod GPU per
user, hands the browser a preshared key, the browser runs real-time video
inference directly against the pod, and ExAtlas reaps the pod when the session
ends or goes idle.

```elixir
# config/config.exs
config :ex_atlas, default_provider: :runpod
config :ex_atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")
config :ex_atlas, start_orchestrator: true
```

```elixir
# LiveView.mount/3
{:ok, pid, compute} =
  ExAtlas.Orchestrator.spawn(
    gpu: :h100,
    image: "ghcr.io/me/my-inference-server:latest",
    ports: [{8000, :http}],
    auth: :bearer,
    user_id: socket.assigns.current_user.id,
    idle_ttl_ms: 15 * 60_000,
    name: "atlas-" <> to_string(socket.assigns.current_user.id)
  )

Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

assign(socket,
  inference_url: hd(compute.ports).url,       # https://<pod-id>-8000.proxy.runpod.net
  inference_token: compute.auth.token         # handed straight to the browser
)
```

Inside the inference server running in the pod:

```elixir
# Any request from the browser must carry the preshared key.
def authenticated?(conn) do
  preshared = System.fetch_env!("ATLAS_PRESHARED_KEY")

  case Plug.Conn.get_req_header(conn, "authorization") do
    ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, preshared)
    _ -> false
  end
end
```

Heartbeat while the browser is active:

```elixir
ExAtlas.Orchestrator.touch(compute.id)
```

When the user leaves, or after `idle_ttl_ms` with no heartbeat, the
`ComputeServer` shuts down and terminates the upstream pod automatically.
You can also terminate manually:

```elixir
:ok = ExAtlas.Orchestrator.stop_tracked(compute.id)
```

## Quick start — serverless inference

```elixir
{:ok, job} =
  ExAtlas.run_job(
    provider: :runpod,
    endpoint: "abc123",
    input: %{prompt: "a beautiful sunset"},
    mode: :async
  )

{:ok, done} = ExAtlas.get_job(job.id, provider: :runpod, endpoint: "abc123")
done.output

# Synchronous with a hard timeout (wrapped in Task.async + Task.yield internally)
{:ok, done} =
  ExAtlas.run_job(
    provider: :runpod,
    endpoint: "abc123",
    input: %{prompt: "a beautiful sunset"},
    mode: :sync,
    timeout_ms: 60_000
  )

# Stream partial output
ExAtlas.stream_job(job.id, provider: :runpod, endpoint: "abc123")
|> Enum.each(&IO.inspect/1)
```

## Swapping providers

```elixir
# Today
ExAtlas.spawn_compute(provider: :runpod,      gpu: :h100, image: "...")

# v0.2
ExAtlas.spawn_compute(provider: :fly,         gpu: :a100_80g, image: "...")
ExAtlas.spawn_compute(provider: :lambda_labs, gpu: :h100, image: "...")

# v0.3
ExAtlas.spawn_compute(provider: :vast,        gpu: :rtx_4090, image: "...")

# Your in-house cloud, today:
ExAtlas.spawn_compute(provider: MyCompany.Cloud.Provider, gpu: :h100, image: "...")
```

All built-in and user-defined providers implement `ExAtlas.Provider`.

## Configuration

```elixir
# config/config.exs

# Provider resolution: per-call :provider option > :default_provider > raise
config :ex_atlas, default_provider: :runpod

# API keys: per-call :api_key > :ex_atlas / :<provider> config > env var
config :ex_atlas, :runpod,      api_key: System.get_env("RUNPOD_API_KEY")
config :ex_atlas, :fly,         api_key: System.get_env("FLY_API_TOKEN")
config :ex_atlas, :lambda_labs, api_key: System.get_env("LAMBDA_LABS_API_KEY")
config :ex_atlas, :vast,        api_key: System.get_env("VAST_API_KEY")

# Start the orchestrator (Registry + DynamicSupervisor + PubSub + Reaper).
# When false (default), ExAtlas boots no processes.
config :ex_atlas, start_orchestrator: true

# Reaper: periodic orphan reconciliation and idle-TTL enforcement.
config :ex_atlas, :orchestrator,
  reap_interval_ms: 60_000,
  reap_providers: [:runpod],
  reap_name_prefix: "atlas-"     # safety switch: only reap resources ExAtlas spawned
```

**Default environment variable names** used when nothing else is set:

| Provider       | Env var              |
| -------------- | -------------------- |
| `:runpod`      | `RUNPOD_API_KEY`     |
| `:fly`         | `FLY_API_TOKEN`      |
| `:lambda_labs` | `LAMBDA_LABS_API_KEY`|
| `:vast`        | `VAST_API_KEY`       |

## Providers

| Provider      | Module                           | Version shipped | Capabilities                                                                        |
| ------------- | -------------------------------- | --------------- | ----------------------------------------------------------------------------------- |
| `:runpod`     | `ExAtlas.Providers.RunPod`         | v0.1            | `:spot, :serverless, :network_volumes, :http_proxy, :raw_tcp, :symmetric_ports, :webhooks, :global_networking` |
| `:fly`        | `ExAtlas.Providers.Fly`            | v0.2 (stub)     | `:http_proxy, :raw_tcp, :global_networking`                                         |
| `:lambda_labs`| `ExAtlas.Providers.LambdaLabs`     | v0.2 (stub)     | `:raw_tcp`                                                                          |
| `:vast`       | `ExAtlas.Providers.Vast`           | v0.3 (stub)     | `:spot, :raw_tcp`                                                                   |
| `:mock`       | `ExAtlas.Providers.Mock`           | v0.1 (tests)    | `:spot, :serverless, :network_volumes, :http_proxy, :raw_tcp, :webhooks`            |

Stub modules return `{:error, %ExAtlas.Error{kind: :unsupported}}` from every
non-`capabilities/0` callback so the name is reserved and callers get a clear
error — no `FunctionClauseError`s.

### Canonical GPU atoms

ExAtlas refers to GPUs by stable atoms. `ExAtlas.Spec.GpuCatalog` maps each atom
to each provider's native identifier.

| Canonical           | RunPod                           | Lambda Labs              | Fly.io            | Vast.ai        |
| ------------------- | -------------------------------- | ------------------------ | ----------------- | -------------- |
| `:h200`             | `"NVIDIA H200"`                  | —                        | —                 | `"H200"`       |
| `:h100`             | `"NVIDIA H100 80GB HBM3"`        | `"gpu_1x_h100_pcie"`     | —                 | `"H100"`       |
| `:a100_80g`         | `"NVIDIA A100 80GB PCIe"`        | `"gpu_1x_a100_sxm4_80gb"`| `"a100-80gb"`     | `"A100_80GB"`  |
| `:a100_40g`         | `"NVIDIA A100-SXM4-40GB"`        | `"gpu_1x_a100_sxm4"`     | `"a100-pcie-40gb"`| `"A100"`       |
| `:l40s`             | `"NVIDIA L40S"`                  | —                        | `"l40s"`          | —              |
| `:l4`               | `"NVIDIA L4"`                    | —                        | —                 | —              |
| `:a6000`            | `"NVIDIA RTX A6000"`             | `"gpu_1x_a6000"`         | —                 | `"RTX_A6000"`  |
| `:rtx_4090`         | `"NVIDIA GeForce RTX 4090"`      | —                        | —                 | `"RTX_4090"`   |
| `:rtx_3090`         | `"NVIDIA GeForce RTX 3090"`      | —                        | —                 | `"RTX_3090"`   |
| `:mi300x`           | `"AMD Instinct MI300X OAM"`      | —                        | —                 | —              |

See `ExAtlas.Spec.GpuCatalog` for the full mapping.

## The `ExAtlas.Provider` behaviour

Every provider implements one callback per operation. See
`ExAtlas.Provider` for the full contract.

| Callback                    | Purpose                                           |
| --------------------------- | ------------------------------------------------- |
| `spawn_compute/2`           | Provision a GPU/CPU resource                      |
| `get_compute/2`             | Fetch current status                              |
| `list_compute/2`            | List with optional filters                        |
| `stop/2` / `start/2`        | Pause / resume                                    |
| `terminate/2`               | Destroy                                           |
| `run_job/2`                 | Submit a serverless job                           |
| `get_job/2` / `cancel_job/2`| Job control                                       |
| `stream_job/2`              | Stream partial outputs                            |
| `capabilities/0`            | Declare supported features                        |
| `list_gpu_types/1`          | Catalog + pricing                                 |

Callers can check `ExAtlas.capabilities(:runpod)` before relying on an
optional feature:

```elixir
if :serverless in ExAtlas.capabilities(provider) do
  ExAtlas.run_job(provider: provider, endpoint: "...", input: %{...})
end
```

### Capability atoms

| Atom                | Meaning                                                               |
| ------------------- | --------------------------------------------------------------------- |
| `:spot`             | Interruptible/spot instances                                          |
| `:serverless`       | `run_job/2` and friends                                               |
| `:network_volumes`  | Attach persistent volumes                                             |
| `:http_proxy`       | Provider terminates TLS on a `*.proxy.*` hostname                     |
| `:raw_tcp`          | Public IP + mapped TCP ports                                          |
| `:symmetric_ports`  | `internal == external` port guarantee                                 |
| `:webhooks`         | Push completion callbacks                                             |
| `:global_networking`| Private networking across datacenters                                 |

## Normalized specs (`ExAtlas.Spec.*`)

Requests and responses flow through normalized structs so callers don't have
to know each provider's native shape.

- `ExAtlas.Spec.ComputeRequest` — input to `spawn_compute/1`. Fields:
  `:gpu`, `:gpu_count`, `:image`, `:cloud_type`, `:spot`, `:region_hints`,
  `:ports`, `:env`, `:volume_gb`, `:container_disk_gb`, `:network_volume_id`,
  `:name`, `:template_id`, `:auth`, `:idle_ttl_ms`, `:provider_opts`.
- `ExAtlas.Spec.Compute` — output. Fields: `:id`, `:provider`, `:status`,
  `:public_ip`, `:ports`, `:gpu_type`, `:gpu_count`, `:cost_per_hour`,
  `:region`, `:image`, `:name`, `:auth`, `:created_at`, `:raw`.
- `ExAtlas.Spec.JobRequest` / `ExAtlas.Spec.Job` — serverless jobs.
- `ExAtlas.Spec.GpuType` — catalog entries returned by `list_gpu_types/1`.
- `ExAtlas.Spec.GpuCatalog` — atom ↔ provider ID mapping.

Every spec struct has a `:raw` field preserving the provider's native
response for callers who need fields ExAtlas hasn't yet normalized.

The `:provider_opts` field on request structs is the escape hatch for
provider-specific options ExAtlas doesn't model — values are stringified and
merged into the outgoing REST body.

## Auth primitives

`ExAtlas.Auth.Token` and `ExAtlas.Auth.SignedUrl` are exposed directly if you
want them without the rest of the orchestration layer.

### Bearer tokens

```elixir
mint = ExAtlas.Auth.Token.mint()
# %{
#   token: "kX9fP...",                              # hand to client once
#   hash:  "4c1...",                                # persist this
#   header: "Authorization: Bearer kX9fP...",
#   env:   %{"ATLAS_PRESHARED_KEY" => "kX9fP..."}   # inject into the pod
# }

ExAtlas.Auth.Token.valid?(candidate, mint.hash)
```

When you pass `auth: :bearer` to `spawn_compute/1`, ExAtlas mints a token,
adds it to the pod's env as `ATLAS_PRESHARED_KEY`, and returns the handle
in `compute.auth` — all in one round-trip.

### S3-style signed URLs

For `<video src>`, `<img src>`, or any client that can't set request
headers:

```elixir
url =
  ExAtlas.Auth.SignedUrl.sign(
    "https://pod-id-8000.proxy.runpod.net/stream",
    secret: signing_secret,
    expires_in: 3600
  )

:ok = ExAtlas.Auth.SignedUrl.verify(url, secret: signing_secret)
```

The signature covers the path + canonicalized query + expiry with
HMAC-SHA256; verification uses constant-time comparison.

## Orchestrator — lifecycle, events, reaper

### `ExAtlas.Orchestrator.spawn/1`

Spawns the resource via the provider, then starts an `ExAtlas.Orchestrator.ComputeServer`
under `ExAtlas.Orchestrator.ComputeSupervisor` that:

1. Registers itself in `ExAtlas.Orchestrator.ComputeRegistry` under `{:compute, id}`.
2. Traps exits — its `terminate/2` always calls `ExAtlas.terminate/2` on the
   upstream provider, whether the supervisor shuts it down or it exits on
   an idle timeout.
3. Tracks `:last_activity_ms` and compares against `:idle_ttl_ms` on every
   heartbeat tick. If idle, the server stops normally and the upstream
   resource is destroyed.

### PubSub events

Every state change is broadcast over `ExAtlas.PubSub` on the topic
`"compute:<id>"` as `{:atlas_compute, id, event}`:

| Event                          | Emitted when                                        |
| ------------------------------ | --------------------------------------------------- |
| `{:status, :running}`          | `ComputeServer` starts                              |
| `{:heartbeat, monotonic_ms}`   | Heartbeat tick (no idle timeout)                    |
| `{:terminating, reason}`       | Server is about to shut down                        |
| `{:status, :terminated}`       | Upstream provider confirmed termination             |
| `{:terminate_failed, error}`   | Upstream `terminate` call returned an error         |

Subscribe in a LiveView:

```elixir
Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

def handle_info({:atlas_compute, _id, {:status, :terminated}}, socket) do
  {:noreply, put_flash(socket, :info, "Session ended")}
end
```

### Reaper

`ExAtlas.Orchestrator.Reaper` runs periodically (configurable, default 60s)
and:

1. Lists each configured provider's running resources.
2. Compares against the resources tracked by the local `ComputeRegistry`.
3. Terminates any orphan whose `:name` starts with `:reap_name_prefix`
   (default `"atlas-"`).

The prefix is a **safety switch** so ExAtlas never touches pods created by
other tools on the same cloud account. Set it to `""` to disable.

## Phoenix LiveDashboard integration

If your Phoenix app already mounts `Phoenix.LiveDashboard`, adding an
**ExAtlas** tab is a one-liner — the library ships
`ExAtlas.LiveDashboard.ComputePage`:

```elixir
# lib/my_app_web/router.ex
import Phoenix.LiveDashboard.Router

live_dashboard "/dashboard",
  metrics: MyAppWeb.Telemetry,
  allow_destructive_actions: true,   # required for Stop/Terminate buttons
  additional_pages: [
    atlas: ExAtlas.LiveDashboard.ComputePage
  ]
```

Visit `/dashboard/atlas` to see a live-refreshing table of every tracked
compute resource with per-row **Touch**, **Stop**, and **Terminate**
controls. The page is only compiled when `:phoenix_live_dashboard` is in
your deps (both LiveDashboard and LiveView are declared as `optional: true`
in ExAtlas, so library-only users pay nothing).

## HTTP layer + telemetry

Every provider uses `Req` under the hood:

- `Authorization: Bearer <api_key>` for REST and serverless runtime endpoints.
- `?api_key=<key>` query param for RunPod's legacy GraphQL (used only for
  the pricing catalog).
- `:retry :transient` with 3 retries by default.
- Connection pooling via `Finch` (Req's default adapter).

### Telemetry events

Every request emits `[:ex_atlas, <provider>, :request]`:

| Measurement | Value                    |
| ----------- | ------------------------ |
| `status`    | HTTP status code          |

| Metadata   | Value                                                                   |
| ---------- | ----------------------------------------------------------------------- |
| `api`      | `:management` / `:runtime` / `:graphql`                                 |
| `method`   | `:get` / `:post` / `:delete` / ...                                      |
| `url`      | Full request URL                                                        |

Wire into your existing telemetry pipeline:

```elixir
:telemetry.attach(
  "atlas-http-logger",
  [:ex_atlas, :runpod, :request],
  fn _event, measurements, metadata, _ ->
    Logger.info("ExAtlas → RunPod #{metadata.method} #{metadata.url} → #{measurements.status}")
  end,
  nil
)
```

### Per-call Req overrides

Any option accepted by `Req.new/1` can be passed via `req_options:`:

```elixir
ExAtlas.spawn_compute(
  provider: :runpod,
  gpu: :h100,
  image: "...",
  req_options: [receive_timeout: 60_000, max_retries: 5, plug: MyPlug]
)
```

## Error handling

All provider callbacks return `{:ok, value}` or `{:error, %ExAtlas.Error{}}`.
The error struct has a stable `:kind` atom you can pattern-match on:

| Kind              | When it happens                                  |
| ----------------- | ------------------------------------------------ |
| `:unauthorized`   | Bad or missing API key (HTTP 401)                |
| `:forbidden`      | API key lacks permission (HTTP 403)              |
| `:not_found`      | Resource doesn't exist (HTTP 404)                |
| `:rate_limited`   | Provider 429                                     |
| `:timeout`        | Client-side timeout (e.g. `run_sync` over cap)   |
| `:unsupported`    | Provider lacks this capability                   |
| `:validation`     | ExAtlas-side validation (e.g. missing `:endpoint`) |
| `:provider`       | Provider-reported 4xx/5xx with no finer bucket   |
| `:transport`      | HTTP/socket failure                              |
| `:unknown`        | Anything else                                    |

```elixir
case ExAtlas.spawn_compute(provider: :runpod, gpu: :h100, image: "...") do
  {:ok, compute} -> ...
  {:error, %ExAtlas.Error{kind: :unauthorized}} -> rotate_key()
  {:error, %ExAtlas.Error{kind: :rate_limited}} -> backoff()
  {:error, err} -> Logger.error(Exception.message(err))
end
```

## Writing your own provider

```elixir
defmodule MyCloud.Provider do
  @behaviour ExAtlas.Provider

  @impl true
  def capabilities, do: [:http_proxy]

  @impl true
  def spawn_compute(%ExAtlas.Spec.ComputeRequest{} = req, ctx) do
    # translate `req` into your cloud's native payload,
    # POST it with Req, normalize the response into %ExAtlas.Spec.Compute{}
  end

  # ... implement the other callbacks ...
end

# Use it without any further configuration:
ExAtlas.spawn_compute(provider: MyCloud.Provider, gpu: :h100, image: "...")
```

Register it with a short atom by mapping it in your own code — ExAtlas
accepts modules directly, so the atom is a convenience:

```elixir
defmodule MyApp.ExAtlas do
  defdelegate spawn_compute(opts), to: ExAtlas
  # Or wrap ExAtlas and inject a default provider module
end
```

## Testing

The `ExAtlas.Test.ProviderConformance` macro runs a shared ExUnit suite
against any provider implementation:

```elixir
defmodule MyCloud.ProviderTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: MyCloud.Provider,
    reset: {MyCloud.TestHelpers, :reset_fixtures, []}
end
```

For unit tests that don't actually talk to a cloud, use the built-in
`ExAtlas.Providers.Mock`:

```elixir
setup do
  ExAtlas.Providers.Mock.reset()
  :ok
end

test "my code is provider-agnostic" do
  {:ok, compute} = MyApp.do_work(provider: :mock)
  assert compute.status == :running
end
```

RunPod tests against the live cloud are tagged `@tag :live` and are
excluded from `mix test` by default — set `RUNPOD_API_KEY` and run
`mix test --only live` to enable them.

## Security considerations

- **Preshared tokens are secrets.** `ExAtlas.Auth.Token.mint/0` returns the
  raw token **once**. Store only the hash. If you must persist the raw
  token (e.g. to render it back to the user on page reload), encrypt at
  rest.
- **`allow_destructive_actions`** on the LiveDashboard route must be gated
  by your own auth pipeline. The ExAtlas page does not authenticate
  operators — LiveDashboard doesn't either. Put it behind `:require_admin`.
- **Reaper safety.** `:reap_name_prefix` is the only thing preventing the
  reaper from terminating pods other tools (or other ExAtlas-using apps) own
  on the same cloud account. Keep the prefix unique per deployment.
- **Outbound egress.** RunPod's `*.proxy.runpod.net` is world-reachable.
  If the pod inside doesn't validate `ATLAS_PRESHARED_KEY` on every request,
  anyone with the URL can hit it.
- **HTTPS only.** Every provider's base URL is HTTPS. If you override via
  `:base_url` (for testing with Bypass), use HTTPS for production.

## Troubleshooting & FAQ

**Q: `(RuntimeError) ExAtlas.Orchestrator is not started`**
You didn't set `config :ex_atlas, start_orchestrator: true`. The orchestrator
is opt-in.

**Q: `{:error, %ExAtlas.Error{kind: :unauthorized}}` on every RunPod call**
Your API key is missing or wrong. Check the resolution order:
per-call `api_key:` → `config :ex_atlas, :runpod, api_key:` → `RUNPOD_API_KEY`
env var.

**Q: `get_job/2` returns `{:error, :validation, message: "requires :endpoint"}`**
RunPod's serverless API is scoped to an endpoint id. Pass it:
`ExAtlas.get_job(job.id, provider: :runpod, endpoint: "abc123")`.

**Q: My LiveDashboard ExAtlas tab is empty.**
Either the orchestrator isn't running, or nothing has been spawned with
`ExAtlas.Orchestrator.spawn/1`. Non-tracked resources (spawned via
`ExAtlas.spawn_compute/1` directly) don't show in the table — they're not
under supervision.

**Q: Stop/Terminate buttons don't show.**
Set `allow_destructive_actions: true` on the `live_dashboard` call.

**Q: I want to use ExAtlas with `httpc` / Mint / Finch directly instead of Req.**
Rewrite the provider module, or pass a custom `Req` adapter via
`req_options: [adapter: my_adapter]`. The ExAtlas.Provider contract doesn't
mandate Req — it's an implementation choice of the bundled providers.

## Roadmap

- **v0.1** — RunPod (full surface), Mock provider, orchestrator, auth,
  LiveDashboard page.
- **v0.2** — Fly.io Machines, Lambda Labs.
- **v0.3** — Vast.ai.

All future providers will be additive; adding a provider never breaks
existing call sites.

## Contributing

PRs welcome. Before opening:

```bash
mix format
mix compile --warnings-as-errors
mix test
mix docs              # verify docstrings render
```

For new providers, the shared conformance suite
(`test/support/provider_conformance.ex`) must pass against your module.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
