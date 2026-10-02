# ExAtlas

[![Hex.pm](https://img.shields.io/hexpm/v/atlas.svg)](https://hex.pm/packages/atlas)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/atlas)
[![License](https://img.shields.io/badge/license-Apache--2.0-green.svg)](LICENSE)

Project docs: [docs/PROJECT.md](docs/PROJECT.md) (roadmap, architecture, risks,
decisions).

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
- [Waiting until a pod is usable](#waiting-until-a-pod-is-usable)
- [Quick start — batch task on a GPU pod](#quick-start--batch-task-on-a-gpu-pod)
- [Data staging — S3 credentials and URIs in the pod](#data-staging--s3-credentials-and-uris-in-the-pod)
- [Pod callbacks — progress, logs, exit codes](#pod-callbacks--progress-logs-exit-codes)
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
 │ v0.1 │ │ stub │ │     v0.8       │ │ stub   │ │    v0.1     │
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

## Waiting until a pod is usable

`spawn_compute/1` and `Orchestrator.spawn/1` return the moment the provider
accepts the rental — 30–90 seconds before the container answers anything. A
LiveView should subscribe and render "starting…"; everything else should block
on `await_ready/2`.

```elixir
# Tracked. Rides the ComputeServer's existing status poll, so it adds no
# requests to your provider, and returns immediately if it is already up.
case ExAtlas.Orchestrator.await_ready(compute.id, timeout_ms: 120_000) do
  {:ok, ready}                 -> hd(ready.ports).url
  {:error, {:dead, reason, _}} -> {:error, reason}   # :failed | :vanished | :preempted | …
  {:error, {:timeout, last}}   -> wait_longer_or_give_up(last)
end

# Untracked — a bare spawn, a script, a mix task. Polls get_compute/2 itself.
ExAtlas.await_ready(id, provider: :runpod, timeout_ms: 120_000, poll_interval_ms: 2_000)
```

- A **failed poll never resolves the wait**: a 5xx or a socket blip means "we
  could not tell", so it backs off and keeps waiting to the timeout.
- A **timeout terminates nothing** — you get the last observed `Compute` back
  and decide.
- It **follows an `on_failure: {:respawn, n}` respawn** to the replacement, on
  the original deadline.

The tracked wait runs in the calling process and consumes that pod's
`{:atlas_compute, id, _}` messages, so run it in a task rather than in a
process that is itself subscribed. See the
[transient pods guide](guides/transient_pods.md).

## Quick start — batch task on a GPU pod

Unattended work that runs to completion, rather than a session a user holds
open:

```elixir
{:ok, _pid, compute} =
  ExAtlas.Orchestrator.run_task(
    provider: :runpod,
    gpu: :rtx_4090,
    image: "ghcr.io/acme/trainer:latest",
    command: ["/app/train.sh", "--epochs", "3"],
    name: "atlas-task-42",
    max_runtime_ms: :timer.minutes(90)
  )

Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

def handle_info({:atlas_compute, _id, {:task, :completed}}, socket) do
  {:noreply, put_flash(socket, :info, "Training finished")}
end

def handle_info({:atlas_compute, _id, {:task, :timed_out}}, socket) do
  {:noreply, put_flash(socket, :error, "Training hit its 90-minute cap")}
end

def handle_info({:atlas_compute, _id, {:task, {:failed, reason}}}, socket) do
  {:noreply, put_flash(socket, :error, "Training failed: #{reason}")}
end
```

No heartbeats, no idle TTL: the pod ends when the command ends, when the
wall-clock deadline fires, or when it dies — and it is always destroyed. See
[`run_task/1`](#exatlasorchestratorrun_task1--run-a-container-to-completion)
for why exit detection needs the container's cooperation, and why
`:completed` does not mean "succeeded" — unless you add a callback.

## Data staging — S3 credentials and URIs in the pod

Pass `s3:` and ExAtlas writes the standard `AWS_*` variables and two ExAtlas
variables into the container: where to read the dataset and where to write
artifacts. ExAtlas makes no S3 call itself.

```elixir
{:ok, _pid, compute} =
  ExAtlas.Orchestrator.run_task(
    provider: :runpod,
    gpu: :rtx_4090,
    image: "ghcr.io/acme/trainer:latest",
    command: ["/app/train.sh"],
    s3: %{
      endpoint: "https://t3.storage.dev",
      region: "auto",
      access_key_id: System.fetch_env!("TIGRIS_KEY_ID"),
      secret_access_key: System.fetch_env!("TIGRIS_SECRET"),
      dataset_uri: "s3://bucket/datasets/abc/",
      artifact_uri: "s3://bucket/artifacts/run-123/"
    }
  )
```

| `s3:` key | Variable(s) in the container |
|---|---|
| `endpoint` | `AWS_ENDPOINT_URL_S3` |
| `region` | `AWS_REGION`, `AWS_DEFAULT_REGION` |
| `access_key_id`, `secret_access_key` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (both or neither) |
| `session_token` | `AWS_SESSION_TOKEN` (needs both keys) |
| `dataset_uri`, `artifact_uri` | `ATLAS_DATASET_URI`, `ATLAS_ARTIFACT_URI` (`s3://bucket/...`) |
| `dataset_url`, `artifact_url` | `ATLAS_DATASET_URL`, `ATLAS_ARTIFACT_URL` (presigned `http://` or `https://` URLs) |

`s3:` needs at least one URI or URL. Presigned URLs put no storage key on the
pod: `s3: %{dataset_url: presigned_get, artifact_url: presigned_put}`. You
presign them yourself, for example with `ExAws.S3.presigned_url/5`; ExAtlas
never presigns.

- A key left out sets no variable. No `endpoint` means AWS S3 itself.
- An `env:` entry that `s3:` would also set raises, naming the variable.
- A bad `s3:` raises `NimbleOptions.ValidationError` with `key: :s3` from
  `spawn_compute/1`, and `Orchestrator.spawn/1` and `run_task/1` return it as
  `{:error, _}`, both before any provider call. The error names the key and
  the rule, never a value. Buckets take letters, digits, `.`, `_` and `-`; an
  endpoint with user info (`https://user:pass@host`) and any control character
  are refused.
- `s3:` goes to the request only, never to a provider's ctx.
  `spawn_compute/2`, which takes a built request, raises on an `s3:` option.
- The credentials and presigned URLs never appear in `inspect/1` of an
  ExAtlas struct, in a tracker's crash report, or in a tracking record. A
  respawn re-injects them.
- `persist: true` with `s3:` stores the endpoint, region and URIs, never the
  keys or presigned URLs. An adopted task runs on, but cannot respawn: a
  preemption after a restart ends it with `{:respawn_failed, {reason,
  %ExAtlas.Error{kind: :validation}}}`, and no pod is rented.

The [data staging guide](guides/data_staging.md) says what the container does
with these variables and ships a tested entrypoint,
[`atlas_entrypoint.sh`](guides/scripts/atlas_entrypoint.sh), that pulls the
dataset, runs your trainer and uploads the artifacts and log.

## Pod callbacks — progress, logs, exit codes

RunPod has no API for pod logs and reports no container state, so for
unattended work the only party that knows what is happening inside the
container is the container. `ExAtlas.Callback` is the supported way for it to
say so: progress reports, streamed log lines, and an exit code declared before
the pod goes.

```elixir
# config/runtime.exs
config :ex_atlas, :callback,
  secret: System.fetch_env!("ATLAS_CALLBACK_SECRET"),  # >= 32 bytes, same on every node
  base_url: "https://app.example.com/atlas/cb"

# lib/my_app_web/router.ex — outside :browser, outside your auth, and NOT
# through Plug.Parsers (its 8 MB default is the memory vector).
scope "/atlas" do
  forward "/cb", ExAtlas.Callback.Plug
end
```

```elixir
{:ok, _pid, compute} =
  ExAtlas.Orchestrator.run_task(
    provider: :runpod,
    gpu: :rtx_4090,
    image: "ghcr.io/acme/trainer:latest",
    command: ["/app/train.sh"],
    callback: "https://app.example.com/atlas/cb"
  )

def handle_info({:atlas_compute, _id, {:progress, payload}}, socket),
  do: {:noreply, assign(socket, pct: payload["pct"])}

def handle_info({:atlas_compute, _id, {:log, payload}}, socket),
  do: {:noreply, stream(socket, :lines, payload["lines"])}

def handle_info({:atlas_compute, _id, {:task, {:failed, {:exit_code, n}}}}, socket),
  do: {:noreply, put_flash(socket, :error, "Training exited #{n}")}
```

The container is handed `ATLAS_CALLBACK_URL`, `ATLAS_CALLBACK_TOKEN` and
`ATLAS_TASK_ID`; the self-termination wrapper already POSTs `/finish` with the
exit code from its `trap`, so only progress and logs need code in your image.

Three things worth knowing up front:

- **`:completed` becomes proven rather than inferred.** With a report, a clean
  exit is a fact and a non-zero one is `{:task, {:failed, {:exit_code, n}}}`.
  It also kills the spot ambiguity: a task that reported `finish` is never
  respawned.
- **ExAtlas retains zero log bytes.** `/logs` is a bus, not a store — no ring
  buffer, no back-pressure, nothing to exhaust. Keep history yourself.
- **No public URL? Omit `:callback`.** Everything reverts precisely to the
  behaviour above. Pointing it at `localhost` is refused at spawn time, because
  a callback that silently never arrives is worse than none at all.

Not using Plug? `ExAtlas.Callback` is framework-free — `verify/1` and
`ingest/3` are all a hand-rolled controller needs, and `:plug` stays an
optional dependency. Full details, container-side examples, rate limits and
the security model are in the
[pod callbacks guide](guides/pod_callbacks.md).

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
ExAtlas.spawn_compute(provider: :lambda_labs, gpu: :h100, image: "...")

# Planned
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
config :ex_atlas, :lambda_labs, api_key: System.get_env("LAMBDA_LABS_API_KEY"),
                                ssh_key_name: "deploy"   # Lambda requires one SSH key
config :ex_atlas, :vast,        api_key: System.get_env("VAST_API_KEY")

# Start the orchestrator (Registry + Task.Supervisor + DynamicSupervisor +
# PubSub + Reaper).
# When false (default), ExAtlas boots no processes.
config :ex_atlas, start_orchestrator: true

# Reaper: periodic orphan reconciliation and idle-TTL enforcement.
config :ex_atlas, :orchestrator,
  reap_interval_ms: 60_000,
  reap_providers: [:runpod],
  reap_name_prefix: "atlas-",    # safety switch: only reap resources ExAtlas spawned
  reap_grace_ms: 60_000,         # spare resources too young to have a tracker yet
  # Required on every machine when more than one shares a provider account.
  # Unique per machine and stable across its restarts — see "More than one node".
  reap_owner: System.get_env("FLY_MACHINE_ID"),

  # Durable tracking, so a deploy does not orphan (and then reap) a running
  # task. Defaults to the DETS store; set `false` to disable persistence.
  tracking_store: ExAtlas.Orchestrator.TrackingStore.Dets,
  storage_path: "/data/ex_atlas",  # a MOUNTED volume — see "Surviving a deploy"
  scrub_keys: []                   # extra opt keys to keep off disk
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
| `:runpod`     | `ExAtlas.Providers.RunPod`         | v0.1            | `:serverless, :network_volumes, :http_proxy, :raw_tcp, :symmetric_ports, :webhooks, :global_networking` |
| `:fly`        | `ExAtlas.Providers.Fly`            | stub            | `:http_proxy, :raw_tcp, :global_networking`                                         |
| `:lambda_labs`| `ExAtlas.Providers.LambdaLabs`     | v0.8 (compute)  | `:raw_tcp`                                                                          |
| `:vast`       | `ExAtlas.Providers.Vast`           | stub            | `:spot, :raw_tcp`                                                                   |
| `:mock`       | `ExAtlas.Providers.Mock`           | v0.1 (tests)    | `:spot, :serverless, :network_volumes, :http_proxy, :raw_tcp, :webhooks`            |

Stub modules return `{:error, %ExAtlas.Error{kind: :unsupported}}` from every
non-`capabilities/0` callback so the name is reserved and callers get a clear
error — no `FunctionClauseError`s.

### Lambda Labs

Lambda rents VMs, not containers. ExAtlas hands the VM a cloud-init
`user_data` script that runs your `image` with `docker run`, passing `env:`,
`s3:`, `auth:` and `ports:` (`-p 8000:8000`). Values reach `docker` through
its environment, never its argv.

```elixir
{:ok, compute} =
  ExAtlas.spawn_compute(
    provider: :lambda_labs,
    gpu: :h100,              # gpu_1x_h100_pcie; gpu_count: 8 launches gpu_8x_...
    image: "vllm/vllm-openai:latest",
    ports: [{8000, :http}],
    region_hints: ["us-east-1"],
    auth: :bearer
  )
# => %Compute{status: :provisioning, cost_per_hour: 2.49, region: "us-east-1"}

{:ok, compute} = ExAtlas.get_compute(compute.id, provider: :lambda_labs)
compute.ports
# => [%{internal: 8000, external: 8000, protocol: :http, url: "http://198.51.100.2:8000"}]
```

- Lambda's firewall admits only port 22 by default. Open your `ports:` in
  the Lambda dashboard; ExAtlas does not change firewall rules yet.
- The spawn picks the first of `region_hints` with capacity, else Lambda's
  first region with capacity. `provider_opts: %{instance_type: "..."}` names
  the type directly.
- `command:` runs in the container. An instance cannot delete itself, so
  with the default `self_terminate: true` it needs a `callback:`: the host
  POSTs the container's exit code, and `run_task/1`'s tracker terminates the
  instance. Without one it is `:validation`; pass `self_terminate: false`.
  See "On Lambda Labs, the host reports instead" in the transient pods guide.
- `stop/2`, `start/2`, `spot: true`, `template_id:` and `network_volume_id:`
  return `:unsupported`.
- The Reaper covers Lambda with `reap_providers: [:lambda_labs]`. It lists
  with no per-call options, so set `config :ex_atlas, :lambda_labs, api_key:`
  (and `base_url:` for a proxy).
- `env:` names starting `DOCKER_` or `LD_` are refused: the script exports
  each value for `docker run` on the host, where docker and the loader read
  them. So are names bash keeps for itself (`UID`, `RANDOM`, `BASH_*`).

### Canonical GPU atoms

ExAtlas refers to GPUs by stable atoms. `ExAtlas.Spec.GpuCatalog` maps each atom
to each provider's native identifier.

| Canonical           | RunPod                           | Lambda Labs              | Fly.io            | Vast.ai        |
| ------------------- | -------------------------------- | ------------------------ | ----------------- | -------------- |
| `:h200`             | `"NVIDIA H200"`                  | —                        | —                 | `"H200"`       |
| `:h100`             | `"NVIDIA H100 80GB HBM3"`        | `"gpu_1x_h100_pcie"`     | —                 | `"H100"`       |
| `:a100_80g`         | `"NVIDIA A100 80GB PCIe"`        | `"gpu_1x_a100_80gb_sxm4"`| `"a100-80gb"`     | `"A100_80GB"`  |
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
| `list/get/create/delete_network_volume` | Optional: manage network volumes     |
| `list/get/create/delete_template` | Optional: manage templates                 |
| `compute_spend/3`           | Optional: one compute resource's spend            |
| `list/get/delete_endpoint`  | Optional: manage serverless endpoints             |

Callers can check `ExAtlas.capabilities(:runpod)` before relying on an
optional feature:

```elixir
if :serverless in ExAtlas.capabilities(provider) do
  ExAtlas.run_job(provider: provider, endpoint: "...", input: %{...})
end
```

### Network volumes

```elixir
{:ok, volume} =
  ExAtlas.create_network_volume(provider: :runpod, name: "datasets", size_gb: 200, region: "EU-RO-1")

ExAtlas.spawn_compute(provider: :runpod, gpu: :h100, image: "...", network_volume_id: volume.id)
ExAtlas.list_network_volumes(provider: :runpod)
ExAtlas.delete_network_volume(volume.id, provider: :runpod)

ExAtlas.list_network_volumes(provider: :lambda_labs)
# => {:error, %ExAtlas.Error{kind: :unsupported}}
```

### Templates

Keep a trainer image as a template and spawn pods from it. A pod spawned with
`template_id:` keeps the template's ports and disk unless the spawn sets
`ports:` or `container_disk_gb:`.

```elixir
{:ok, template} =
  ExAtlas.create_template(
    provider: :runpod,
    name: "trainer-v7",
    image: "ghcr.io/acme/trainer:7",
    ports: [{8000, :http}],
    env: %{"WANDB_PROJECT" => "atlas"},
    container_disk_gb: 80,
    volume_gb: 100
  )

ExAtlas.spawn_compute(provider: :runpod, gpu: :h100, template_id: template.id)
ExAtlas.list_templates(provider: :runpod)
ExAtlas.delete_template(template.id, provider: :runpod)
```

RunPod starts SSH and Jupyter in a template's pods by default. Pass
`ssh: false` or `jupyter: false` to `create_template/1` to turn one off.
`inspect/1` of a `%ExAtlas.Spec.Template{}` leaves out `env` and `raw`.

### Spend

What one pod has cost, in US dollars, split into GPU, CPU and disk:

```elixir
{:ok, spend} = ExAtlas.compute_spend("pod_9", provider: :runpod)
spend.total_usd
# => 12.34
spend.from
# => ~U[2026-09-01 00:00:00Z]

ExAtlas.compute_spend("pod_9", provider: :runpod, from: ~U[2026-09-30 00:00:00Z])
ExAtlas.compute_spend("pod_9", provider: :fly)
# => {:error, %ExAtlas.Error{kind: :unsupported}}
```

With no `from:` or `to:`, RunPod covers its last 30 days. `from` and `to` on
the result are the window RunPod resolved, `[from, to)`, snapped to its
billing buckets. RunPod's docs do not say how soon a new hour of spend shows
up, so do not read the total as a live cost.

### Serverless endpoints

Find the id that `run_job/1` takes, without RunPod's console:

```elixir
{:ok, [endpoint | _]} = ExAtlas.list_endpoints(provider: :runpod)
endpoint.name
# => "image-generator"
endpoint.type
# => :queue
{endpoint.workers_min, endpoint.workers_max, endpoint.gpu_pools}
# => {0, 3, ["ADA_24"]}

ExAtlas.run_job(provider: :runpod, endpoint: endpoint.id, input: %{prompt: "a fox"})
ExAtlas.get_endpoint(endpoint.id, provider: :runpod)
ExAtlas.delete_endpoint(endpoint.id, provider: :runpod)
# => :ok
```

`gpu_pools` holds RunPod's pool ids (`"ADA_24"`), not card names. `type` is
`:queue`, `:load_balancer`, `:unknown` for a type this library does not know,
or `nil`. ExAtlas does not create endpoints: create one in RunPod's console.
`inspect/1` of a `%ExAtlas.Spec.Endpoint{}` leaves out `raw`, which holds the
endpoint's env.

### Capability atoms

| Atom                | Meaning                                                               |
| ------------------- | --------------------------------------------------------------------- |
| `:spot`             | Interruptible/spot instances                                          |
| `:serverless`       | `run_job/2` and friends                                               |
| `:network_volumes`  | Attach persistent volumes                                             |
| `:manage_network_volumes` | Create, list, get and delete volumes                            |
| `:manage_templates` | Create, list, get and delete templates                                |
| `:manage_endpoints` | List, get and delete serverless endpoints                             |
| `:billing`          | `compute_spend/2`                                                     |
| `:http_proxy`       | Provider terminates TLS on a `*.proxy.*` hostname                     |
| `:raw_tcp`          | Public IP + mapped TCP ports                                          |
| `:symmetric_ports`  | `internal == external` port guarantee                                 |
| `:webhooks`         | Push completion callbacks                                             |
| `:global_networking`| Private networking across datacenters                                 |
| `:self_terminate`   | Honors `:self_terminate` — wraps `:command` so the resource ends itself |

## Normalized specs (`ExAtlas.Spec.*`)

Requests and responses flow through normalized structs so callers don't have
to know each provider's native shape.

- `ExAtlas.Spec.ComputeRequest` — input to `spawn_compute/1`. Fields:
  `:gpu`, `:gpu_count`, `:image`, `:cloud_type`, `:spot`, `:region_hints`,
  `:ports`, `:env`, `:volume_gb`, `:container_disk_gb`, `:network_volume_id`,
  `:name`, `:template_id`, `:auth`, `:idle_ttl_ms`, `:command`,
  `:self_terminate`, `:callback`, `:s3`, `:provider_opts`.
  `ComputeRequest.container_env/1` returns the env a provider sends to the
  container.
- `ExAtlas.Spec.Staging` — the validated `s3:` option. `inspect/1` shows the
  endpoint, region and URIs, never a credential or a presigned URL.
- `ExAtlas.Spec.Compute` — output. Fields: `:id`, `:provider`, `:status`,
  `:public_ip`, `:ports`, `:gpu_type`, `:gpu_count`, `:cost_per_hour`,
  `:region`, `:image`, `:name`, `:auth`, `:created_at`, `:raw`.
  `inspect/1` leaves out `:raw`: RunPod echoes the container env there.
- `ExAtlas.Spec.JobRequest` / `ExAtlas.Spec.Job` — serverless jobs.
- `ExAtlas.Spec.Endpoint` — serverless endpoint from `list_endpoints/1`.
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

### Callback tokens

`ExAtlas.Callback.Token` is the *inbound* direction — the credential a pod
presents when calling back into your app. It is a stateless signed token
(`Plug.Crypto.sign/4` over `%{task_id, kinds}`, verified in constant time),
bound to a task id rather than a compute id, and deliberately **not** the same
credential as `ATLAS_PRESHARED_KEY`: that one is handed to a browser, and a
browser-held secret must never also authorize writing into your orchestrator.
See the [pod callbacks guide](guides/pod_callbacks.md).

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
4. Polls the provider every `:status_poll_ms` and reports what it finds, so a
   resource that died on the cloud's side is noticed rather than assumed away.

### Upstream status polling

The heartbeat answers "does anyone still want this?"; it cannot answer "is it
still there?". A pod can die without you asking — a host fails, an image
crash-loops, spot capacity is reclaimed — and until the tracker asks the
provider, subscribers go on believing the session is healthy and the meter
goes on running.

So the `ComputeServer` runs a second, independent clock. Every
`:status_poll_ms` (default 60s) it calls `get_compute/2` and broadcasts the
result: a status change while the resource is alive, or the cause of death
followed by a normal shutdown.

```elixir
ExAtlas.Orchestrator.spawn(
  gpu: :h100,
  image: "ghcr.io/me/trainer:latest",
  spot: true,
  status_poll_ms: 30_000,          # false to disable polling entirely
  on_failure: {:respawn, 3}        # replace preempted pods, up to 3 times
)
```

| Option              | Default  | Meaning                                          |
| ------------------- | -------- | ------------------------------------------------ |
| `:status_poll_ms`   | `60_000` | Poll interval; `false` disables polling          |
| `:on_failure`       | `:stop`  | Or `{:respawn, max_attempts}` for spot workloads  |

The interval is separate from `:heartbeat_ms` on purpose: one is paced by your
users' activity, the other by what your provider's API tolerates. RunPod's
management API publishes no rate limits at all, which is why the default is
unhurried and why polls back off exponentially (with jitter, so a fleet of
trackers doesn't poll in lockstep) while the provider is failing.

**A failed poll is not a death.** Only a `404` means the resource is gone.
A 500, a rate limit, a socket error, a malformed body, even a bad API key
come back as `{:poll_failed, error}` — the poller backs off and the session
continues. Tearing down a live GPU because one request failed is far more
expensive than noticing a death a minute late.

**Preemption is inferred, not reported.** No provider publishes a "you were
outbid" signal, and Runpod no longer sells spot pods at all (`spot: true` on
`:runpod` returns `{:error, %ExAtlas.Error{kind: :unsupported}}`). So a resource
on a provider that still sells spot, spawned with `spot: true`, that stops, is terminated, or vanishes without
you asking is reported as `{:status, :preempted}`. On-demand resources keep
the literal reason (`:stopped`, `:terminated`, `:vanished`).

With `on_failure: {:respawn, n}` a preempted resource is replaced from the
same opts rather than ending the session: the tracker terminates the old
resource if the provider still has it, re-keys itself under the new id, and
emits `{:respawned, new_id}` on the *old* topic. The event carries the id and
nothing else — the replacement's URL and bearer token come from
`ExAtlas.Orchestrator.info(new_id)`, which is readable by the time the event
lands, and a live credential has no business on a PubSub topic. Only
preemption is retried — a stopped or terminated resource was ended by someone,
and an image that `:failed` here will fail on the next host too.

`ExAtlas.Orchestrator.UpstreamStatus` is the primitive underneath, usable on
its own if you want the classification without a tracker process:

```elixir
ExAtlas.Orchestrator.UpstreamStatus.observe(pod_id, provider: :runpod, spot: true)
# {:alive, %ExAtlas.Spec.Compute{}}
# {:dead, :preempted, nil}
# {:poll_failed, %ExAtlas.Error{}}
```

### A cost cap: `max_cost`

```elixir
{:ok, _pid, compute} =
  ExAtlas.Orchestrator.spawn(gpu: :h100, image: "ghcr.io/me/app:latest", max_cost: 2.50)

ExAtlas.Orchestrator.info(compute.id)
# {:ok, %{..., max_cost: 2.5, spent_usd: 0.41}}
```

The tracker multiplies the pod's `cost_per_hour` by the time it has run, and
deletes the pod when that reaches `max_cost` US dollars. Subscribers get
`{:terminating, :cost_cap}`; a task gets `{:task, {:failed, :cost_cap}}` first.
It works in both modes.

* The spend is an estimate from the price the provider reports. A status poll
  with a new price re-prices the rest of the run; a poll with no price keeps
  the last one. A respawn carries the spend and is never triggered by the cap.
* A timer fires at the moment the cap is reached, not on the next heartbeat.
* A provider that reports no price (`cost_per_hour: nil`) gets its pod deleted
  and `{:error, %ExAtlas.Error{kind: :unsupported}}` back.
* With `persist: true` the tracking record carries the spend. An adopted task
  resumes its budget, and the time the node was down counts at the last known
  price, since the pod billed through it.
* Every 15 minutes the tracker asks the provider for the current pod's bill
  (`ExAtlas.compute_spend/2`). A bill above the estimate becomes the spend, so
  the cap fires sooner. A lower bill changes nothing: RunPod's billing lags by
  an amount its docs do not state, so a low bill may only be late. A provider
  with no billing API is asked once, and the session runs on the estimate.

```elixir
# estimate $1.49, RunPod bills $1.80
# {:atlas_compute, id, {:spend_reconciled, %{estimated_usd: 1.49, billed_usd: 1.8, spent_usd: 1.8}}}
```

| Option                | Default  | Meaning                                                  |
| --------------------- | -------- | -------------------------------------------------------- |
| `:max_cost`           | `false`  | US dollars; a positive number. Delete the pod at it      |
| `:reconcile_spend_ms` | 15 min   | How often to read the bill when `max_cost` is set; `false` turns it off |

### PubSub events

Every state change is broadcast over `ExAtlas.PubSub` on the topic
`"compute:<id>"` as `{:atlas_compute, id, event}`:

| Event                                | Emitted when                                                                   |
| ------------------------------------ | ------------------------------------------------------------------------------ |
| `{:status, status}`                  | `ComputeServer` starts (whatever the resource's status is), and on every upstream status change |
| `{:heartbeat, monotonic_ms}`         | Heartbeat tick (no idle timeout)                                               |
| `{:status, :preempted}`              | A `spot: true` resource was reclaimed                                          |
| `{:status, :failed \| :stopped \| :vanished}` | A poll found the resource dead                                       |
| `{:poll_failed, error}`              | A status poll couldn't reach the provider, or blew up trying                    |
| `{:respawned, new_id}`               | Preempted resource replaced (sent on the old id)                               |
| `{:respawn_failed, {reason, error}}` | Replacement couldn't be spawned                                                |
| `{:task, outcome}`                   | A `mode: :task` session ended: `:completed`, `:timed_out`, `{:failed, reason}`  |
| `{:spend_reconciled, %{estimated_usd: e, billed_usd: b, spent_usd: s}}` | The tracker read the current pod's bill; `e` is this pod's estimate, `s` the session's spend after |
| `{:spend_reconcile_failed, error}`   | Reading the bill failed; nothing changed, and it is read again next interval    |
| `{:terminating, :cost_cap}`          | The spend reached `max_cost`; teardown follows                                  |
| `{:terminating, reason}`             | Server is about to shut down                                                   |
| `{:status, :terminated}`             | Upstream provider confirmed termination, or had nothing left to terminate       |
| `{:terminate_failed, error}`         | Upstream `terminate` call returned an error                                    |

`{:terminating, _}` followed by `{:status, :terminated}` is the end-of-session
signal; no individual status is.

Subscribe in a LiveView:

```elixir
Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

def handle_info({:atlas_compute, _id, {:status, :terminated}}, socket) do
  {:noreply, put_flash(socket, :info, "Session ended")}
end
```

### `ExAtlas.Orchestrator.run_task/1` — run a container to completion

The third compute shape, alongside interactive per-user pods and serverless
jobs: *run this image with this command until it exits, then tell me the
outcome and stop the meter.*

```elixir
{:ok, pid, compute} =
  ExAtlas.Orchestrator.run_task(
    provider: :runpod,
    gpu: :rtx_4090,
    image: "ghcr.io/acme/trainer:latest",
    command: ["/app/train.sh", "--epochs", "3"],
    name: "atlas-task-42",
    max_runtime_ms: :timer.minutes(90)
  )

Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)
```

| Option              | Default    | Meaning                                                    |
| ------------------- | ---------- | ---------------------------------------------------------- |
| `:command`          | `nil`      | Overrides the image's start command (`cmd` on Runpod)       |
| `:self_terminate`   | `true`     | Wrap `:command` so the resource destroys itself on exit     |
| `:max_runtime_ms`   | 60 min     | Wall-clock deadline **from spawn**; then `DELETE`           |
| `:ready_timeout_ms` | 15 min     | Fail as `:never_ready` if still provisioning when it fires  |
| `:max_cost`         | `false`    | US dollars; fail as `:cost_cap` when the spend reaches it   |

Task mode is the same `ComputeServer`, so everything above still applies —
the status poll, the backoff, the guaranteed `DELETE` on teardown, the respawn
option. Three things differ:

* **No idle clock.** The heartbeat is never scheduled and `touch/1` has
  nothing to postpone. Unattended work has no heartbeats to miss, and the
  30-minute default idle TTL would otherwise kill a 90-minute run.
* **A wall-clock deadline** measured from spawn, not from `:running`. Billing
  starts when the resource is rented and an image pull is exactly the
  unbounded cost worth capping. It **carries across an `on_failure:
  {:respawn, n}` replacement** rather than resetting: a caller who asked for
  90 minutes must not be able to spend 360 by being preempted three times.
* **A readiness deadline**, much shorter, so an image that never pulls fails
  in minutes rather than burning the whole budget.

#### Why exit detection needs the container's help

Runpod's REST v2 API exposes **no exit code and no restart count**: the `Pod`
body has a `runtime` object (uptime, GPUs, ports), but `status` stays `RUNNING`
when your command exits, and Runpod restarts the container. A live probe
(2026-09-30) read `RUNNING` 180 seconds after a 30-second command, which had
started 6 times. The GPU stays reserved, and no amount of polling can tell that
the work is done.

The only party that knows is the container. With `self_terminate: true`
ex_atlas wraps your command in a shell that deletes the pod when it ends:

```sh
atlas_self_terminate() {
  curl -sS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" \
    "https://api.runpod.io/v2/pods/$RUNPOD_POD_ID"
}
trap atlas_self_terminate EXIT INT TERM
/app/train.sh --epochs 3
```

`RUNPOD_POD_ID` and the pod-scoped `RUNPOD_API_KEY` are injected by RunPod, so
no secret of yours travels to the pod, and `trap … EXIT` fires on a crash and
on a signal as well as on a clean finish. The orchestrator sees the resulting
404 and reports `{:task, :completed}`.

Pass `self_terminate: false` for an image with no shell or no `curl`, or when
you want the resource kept up for inspection. Such a task will always end at
`:max_runtime_ms` and report `:timed_out`, which is honest.

**Self-termination and the deadline are both required — they cover disjoint
failures.** Self-termination is the only source of a normal-exit signal; the
deadline is the only cover for a SIGKILL or OOM kill that runs no cleanup, a
hung process, an image that never pulled, and `self_terminate: false`.

#### `:completed` does not mean "succeeded"

It means **the container ended and the resource is gone**. `trap … EXIT` fires
on a crash too, so success and failure arrive as the same 404, and the exit
code dies with the pod. If you need the difference, have the container report
it before it exits — a status file on a network volume, a call to your own
webhook.

#### Spot tasks

With `spot: true` a resource that vanished is reported as `:preempted`, and a
self-terminating container also makes it vanish — so on spot capacity the two
are indistinguishable through the API. `on_failure: {:respawn, n}` can
therefore re-run a task that had actually finished. Use it only where
re-running is harmless (checkpoint-resuming training, which is what the option
was added for); the carried deadline bounds the total spend either way.

### Reaper

`ExAtlas.Orchestrator.Reaper` runs periodically (configurable, default 60s)
and:

1. Lists each configured provider's running resources.
2. Compares against the resources tracked by the local `ComputeRegistry`
   **and** recorded in the tracking store (see "Surviving a deploy").
3. Terminates any orphan whose `:name` starts with `:reap_name_prefix`
   (default `"atlas-"`) and that is older than `:reap_grace_ms`.

The prefix is a **safety switch** so ExAtlas never touches pods created by
other tools on the same cloud account. Set it to `""` to disable.

### More than one node

Every machine lists the whole provider account, and knows only its own pods.
Without an owner, machine B deletes machine A's live pods once they pass the
grace window. **Every deployment with more than one machine on one provider
account must set `:reap_owner` on every machine**, unique per machine and the
same across that machine's restarts:

```elixir
# config/runtime.exs
config :ex_atlas, :orchestrator, reap_owner: System.get_env("FLY_MACHINE_ID")
```

Use `a-z` and `0-9`, 1 to 32 characters. On Fly, `FLY_MACHINE_ID` fits. Do
not use `node()`: the Phoenix Fly template puts the image ref in
`RELEASE_NODE`, so it changes on every deploy.

With an owner set:

- `ExAtlas.Orchestrator.spawn/1` writes it into the pod name:
  `atlas-train-42` becomes `atlas-m1-train-42`. Respawns and tracking records
  keep that name.
- The Reaper deletes only untracked pods named with its own owner. It leaves
  every other prefixed pod alone and logs each once per boot, with its id and
  the owner it carries. Pods of a machine that is gone are yours to delete.
- The Adopter adopts only the tracking records that carry its own owner, so
  machines can share one database-backed store (see "Surviving a deploy").

The Reaper reaps nothing and logs an error when the owner is invalid, when a
machine with no owner is connected to other nodes, or when a connected node
reports the same owner. Those checks see **connected** nodes only:

- A machine with no owner that sees no peers reaps as v0.7.0 did. Machines
  that share an account without clustering, or a node before its cluster
  connects, still delete each other's pods. An owner set on only some
  machines protects nothing.
- Two machines with the same owner that are not connected delete each
  other's pods with no error.
- A connected node that cannot report its owner, such as a v0.7.0 node
  mid-upgrade, gets one warning per boot naming it. Reaping goes on.
- An owner can claim older pod names. A pod named `atlas-train-42` before
  owners existed carries owner `train` to the Reaper, so a machine with owner
  `train` deletes it. Pick an owner that no pre-v0.8 pod name starts with.
  With `reap_name_prefix: ""` the owner is the first word of any pod name.

Upgrading a cluster from v0.7.0 takes two deploys, because a v0.7.0 node
running beside a v0.8.0 node deletes the new node's pods:

1. Deploy v0.7.0 with `reap_providers: []`, so no node reaps.
2. Deploy v0.8.0 with `:reap_owner` set and `reap_providers` restored.

Pods named by v0.7.0 carry no owner after the upgrade and are left alone.
Their trackers still end them: adopted tasks by deadline, live sessions by
idle TTL.

The Reaper and the status poller look in opposite directions: the Reaper asks
"is anything running that nothing is tracking?" (provider → local), while each
tracker asks "is the thing I track still alive?" (local → provider). Between
them, a resource can neither outlive its tracker nor be believed alive after
it dies.

They do meet in one place. A resource is created upstream *before* its tracker
is registered — by `spawn/1`, and again by every respawn — so for the duration
of that provider call it looks exactly like an orphan. The Reaper therefore
leaves resources younger than `:reap_grace_ms` (default: one reap interval)
alone, and only resources reporting no `created_at` at all skip the grace.
Shorten the grace and you shorten how long a genuine orphan bills; shorten it
below your provider's worst-case spawn latency and the Reaper starts killing
brand-new resources.

### Surviving a deploy: the tracking store

The Registry is in memory and the trackers are `restart: :temporary`, so a
**deploy empties them while your pods keep running**. Every one of those pods
is then old, prefix-matching and untracked — an orphan by the rules above — and
the Reaper terminates it on the first tick. `:reap_grace_ms` cannot save it: the
window is keyed off `created_at`, and a pod that has been training for three
hours is not young.

`ExAtlas.Orchestrator.TrackingStore` is the fix. Opt a task in with
`persist: true`:

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  gpu: :h100,
  image: "ghcr.io/acme/trainer:latest",
  command: ["/app/train.sh"],
  name: "atlas-train-#{run.id}",
  max_runtime_ms: :timer.hours(6),
  persist: true
)
```

At the next boot `ExAtlas.Orchestrator.Adopter` reads the store, asks the
provider whether each id still exists, and starts a tracker for the ones that
do. The Reaper waits for it: with a store configured it reaps **nothing** until
adoption has settled, and if the store could not be read it reaps nothing for
the whole boot — a node that cannot tell which pods are its own must never
issue a DELETE.

What an adopted task keeps:

| Carried across the restart | Why |
| -------------------------- | --- |
| `:max_runtime_ms` deadline | Recomputed from a **wall-clock** anchor, so a 90-minute task that was down for two hours ends immediately instead of starting a second 90 minutes. |
| `on_failure: {:respawn, n}` budget | A restart must not refill it. |
| A landed `finish` report | So work that already reported is never re-run. |
| The callback `task_id` | In-flight pod callbacks stop answering `410 Gone`. |
| `max_cost` and the spend so far | The downtime counts at the last known price, so a task that spent $2 of $2.50 resumes with $0.50, and one whose budget ran out while the node was down fails with `:cost_cap` at once. |

Seven things to know before you rely on it:

- **Tasks only.** `persist: true` requires `mode: :task` and is refused
  otherwise. An interactive session's bearer token is never written to disk, so
  an adopted one would be a pod nobody can authenticate to, billing for another
  full idle TTL.
- **The DETS default needs a durable filesystem.** It writes to `priv` (or
  `tmp`), and **a Fly machine with no attached volume gets a fresh filesystem
  on every deploy** — the store comes up empty, adoption silently does nothing,
  and the pods are reaped anyway. Mount a volume and point `:storage_path` at
  it, or supply your own store.
- **The behaviour is the real feature.** `ExAtlas.Orchestrator.TrackingStore`
  is five callbacks; implement it against Postgres or anything else you already
  trust to survive a deploy, and set
  `config :ex_atlas, :orchestrator, tracking_store: MyApp.AtlasStore`. The
  shared conformance suite in `test/support` gives your implementation the
  contract tests for free.
- **A shared store needs a `:reap_owner` on every node.** Each record carries
  its spawning node's owner, and a node adopts only its own records. A record
  of another owner stays untouched and the boot logs its id. The first node to
  adopt an unowned record (one written before v0.8.0) claims it. A dead
  owner's pods and records stay until you delete them: "node A died, node B
  takes over" needs leases and is out of scope. A store that maps fields to
  columns needs a nullable `owner` column, and from v0.8.0 the four cost
  columns `max_cost`, `spent_usd`, `cost_rate` and `cost_since_ms` (the last
  two nullable). See "More than one node".
- **A graceful deploy keeps the pod; your kill signal decides the rest.** On
  SIGTERM the BEAM stops the app and every tracker runs `terminate/2`. A
  `persist: true` task whose container has not reported an exit code keeps its
  pod and its record; every other tracker deletes its pod, as does a persisted
  task whose record is missing from the store. Fly's default
  `kill_signal` is SIGINT, which on OTP 27 halts the VM with no `terminate/2`
  at all: persisted pods survive and unpersisted ones are left to the Reaper.
  `fly launch` writes `kill_signal = "SIGTERM"` for Phoenix apps. Use it, with
  a `kill_timeout` of at least 30 s (Fly's default is 5 s) so unpersisted
  trackers finish their DELETE.
- **A machine removed for good keeps its persisted pods too.** `fly scale
  count` down and `fly machine destroy` send the same SIGTERM as a deploy, and
  the app cannot tell them apart. The pod runs with no tracker and no
  `:max_runtime_ms` cap until its container exits or you delete it. The Reaper
  on the remaining machines leaves it alone and logs it as another owner's.
- **`stop_tracked/1` is how you end one.** It deletes the pod and the record,
  persisted or not. `DynamicSupervisor.terminate_child/2` on
  `ExAtlas.Orchestrator.ComputeSupervisor` counts as a node stop and keeps a
  persisted pod.

Nothing here is on by default. With `persist: false` — the default — the
orchestrator behaves exactly as it did before the store existed.

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
- `:retry :transient` with 3 retries by default.
- Connection pooling via `Finch` (Req's default adapter).

### Telemetry events

Every request emits `[:ex_atlas, <provider>, :request]`:

| Measurement | Value                    |
| ----------- | ------------------------ |
| `status`    | HTTP status code          |

| Metadata   | Value                                                                   |
| ---------- | ----------------------------------------------------------------------- |
| `api`      | `:management` / `:runtime`                                              |
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
- **Reaper safety.** `:reap_name_prefix` keeps the reaper away from pods other
  tools (or other ExAtlas-using apps) own on the same cloud account. Keep the
  prefix unique per deployment. Within one deployment, `:reap_owner` keeps
  each machine away from the others' pods; set it on every machine (see "More
  than one node").
- **Credentials print as `#ExAtlas.Secret<redacted>`.** ExAtlas wraps
  `api_key:`, the `:auth`, `:headers` and `:aws_sigv4` entries of
  `req_options:`, and every `env:` value in `ExAtlas.Secret` where it first
  receives them, so a crash in a tracker or a provider prints none of them.
  `env:` names stay readable. `inspect/1` of a
  `Spec.Compute` leaves out `auth`. Your own frames hold what you pass: pass
  `api_key: ExAtlas.Secret.wrap(key)` to cover them too.
- **The tracking store is on disk.** Records are scrubbed of `:api_key` and
  friends and never hold `compute.auth.token` or an `env:` value. `env:`
  keeps its names, each with the value `:not_stored`. An adopted task runs
  on, but a preemption after adoption ends it with `{:respawn_failed, ...}`:
  the record has no values to give a replacement. A record written before
  0.8.0 still holds its values until its task ends. The DETS default is
  `0700`/`0600`.
- **`s3:` credentials go to a third-party GPU host.** They sit in the pod's
  environment, where anyone with access to the pod can read them. Give the
  pod keys scoped to the dataset and artifact prefixes, with a short life
  (`session_token`), or pass two presigned URLs instead (`dataset_url`,
  `artifact_url`), which reach one object each until they expire. ExAtlas
  keeps both out of its own structs, crash reports and tracking records.
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

**Q: My pod died on RunPod but my app never noticed.**
Upstream polling is on by default (`:status_poll_ms`, 60s). If you set it to
`false`, nothing asks the provider anything and the session only ends on idle
TTL. Note that a `{:poll_failed, _}` event means the *poll* failed, not the
pod — check that event before assuming the resource is gone.

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
- **v0.8** — Lambda Labs compute: spawn, get, list, terminate, `command:`,
  `run_task/1` and the Reaper. Next: firewall ports.
- Fly.io Machines GPUs: Fly retired GPU Machines on 2026-07-31, so the `:fly`
  compute provider stays a stub. `ExAtlas.Fly` platform ops are unaffected.
- Vast.ai.

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
