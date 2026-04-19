# Atlas

A composable, pluggable Elixir SDK for managing GPU and CPU compute across
cloud providers. Spawn pods, run serverless inference, and orchestrate
transient per-user GPU sessions with a single API — swap providers by
changing one option.

- **One contract, many providers.** `Atlas.Provider` is a behaviour; swap
  `:runpod`, `:fly`, `:lambda_labs`, `:vast`, or your own module without
  changing call sites.
- **Batteries-included orchestration.** Opt-in `Registry` + `DynamicSupervisor`
  + `Phoenix.PubSub` + reaper for the "per-user transient pod" pattern.
- **Built for the S3-style handoff.** `Atlas.Auth` mints bearer tokens and
  S3-style HMAC-signed URLs so your browser can talk directly to a pod without
  the Phoenix app proxying every frame.
- **Pure `Req` under the hood.** Every HTTP call goes through
  [Req](https://hex.pm/packages/req), so you get retries, decoding, and
  telemetry for free.

## Installation

Add `atlas` to your `deps` in `mix.exs`:

```elixir
def deps do
  [
    {:atlas, "~> 0.1"}
  ]
end
```

## Quick start — spawn a GPU pod for a user

The motivating use case: a Fly.io-hosted Phoenix app spawns a RunPod GPU per
user, hands the browser a preshared key, the browser runs real-time video
inference directly against the pod, and Atlas reaps the pod when the session
ends or goes idle.

```elixir
# config/config.exs
config :atlas, default_provider: :runpod
config :atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")
config :atlas, start_orchestrator: true

# LiveView.mount/3
{:ok, pid, compute} =
  Atlas.Orchestrator.spawn(
    gpu: :h100,
    image: "ghcr.io/me/my-inference-server:latest",
    ports: [{8000, :http}],
    auth: :bearer,
    user_id: socket.assigns.current_user.id,
    idle_ttl_ms: 15 * 60_000,
    name: "atlas-" <> to_string(socket.assigns.current_user.id)
  )

Phoenix.PubSub.subscribe(Atlas.PubSub, "compute:" <> compute.id)

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
Atlas.Orchestrator.touch(compute.id)
```

When the user leaves, or after `idle_ttl_ms` with no heartbeat, the
`ComputeServer` shuts down and terminates the upstream pod automatically.
You can also terminate manually:

```elixir
:ok = Atlas.Orchestrator.stop_tracked(compute.id)
```

## Quick start — serverless inference

```elixir
{:ok, job} =
  Atlas.run_job(
    provider: :runpod,
    endpoint: "abc123",
    input: %{prompt: "a beautiful sunset"},
    mode: :async
  )

{:ok, done} = Atlas.get_job(job.id, provider: :runpod, endpoint: "abc123")
done.output

# Or stream
Atlas.stream_job(job.id, provider: :runpod, endpoint: "abc123")
|> Enum.each(&IO.inspect/1)
```

## Swapping providers

```elixir
# Today
Atlas.spawn_compute(provider: :runpod,      gpu: :h100, image: "...")

# v0.2
Atlas.spawn_compute(provider: :fly,         gpu: :a100_80g, image: "...")
Atlas.spawn_compute(provider: :lambda_labs, gpu: :h100, image: "...")

# v0.3
Atlas.spawn_compute(provider: :vast,        gpu: :rtx_4090, image: "...")

# Your in-house cloud, today:
Atlas.spawn_compute(provider: MyCompany.Cloud.Provider, gpu: :h100, image: "...")
```

All built-in and user-defined providers implement `Atlas.Provider`. See
[Writing your own provider](#writing-your-own-provider) below.

## Configuration

```elixir
# config/config.exs

# Provider resolution: per-call :provider option > :default_provider > raise
config :atlas, default_provider: :runpod

# API keys: per-call :api_key > :atlas / :<provider> config > env var
config :atlas, :runpod,      api_key: System.get_env("RUNPOD_API_KEY")
config :atlas, :fly,         api_key: System.get_env("FLY_API_TOKEN")
config :atlas, :lambda_labs, api_key: System.get_env("LAMBDA_LABS_API_KEY")
config :atlas, :vast,        api_key: System.get_env("VAST_API_KEY")

# Start the orchestrator (Registry + DynamicSupervisor + PubSub + Reaper)
config :atlas, start_orchestrator: true

# Reaper safeguard: only terminate resources whose :name starts with this prefix,
# so Atlas never touches pods spawned by other tools on the same account.
config :atlas, :orchestrator,
  reap_interval_ms: 60_000,
  reap_providers: [:runpod],
  reap_name_prefix: "atlas-"
```

## The `Atlas.Provider` behaviour

Every provider implements one callback per operation. See
`Atlas.Provider` for the full contract. The summary:

| Callback                    | Purpose                                           |
| --------------------------- | ------------------------------------------------- |
| `spawn_compute/2`           | Provision a GPU/CPU resource                       |
| `get_compute/2`             | Fetch current status                               |
| `list_compute/2`            | List with optional filters                         |
| `stop/2` / `start/2`        | Pause / resume                                     |
| `terminate/2`               | Destroy                                            |
| `run_job/2`                 | Submit a serverless job                            |
| `get_job/2` / `cancel_job/2`| Job control                                        |
| `stream_job/2`              | Stream partial outputs                             |
| `capabilities/0`            | Declare supported features                         |
| `list_gpu_types/1`          | Catalog + pricing                                  |

Callers can check `Atlas.capabilities(:runpod)` before relying on an
optional feature:

```elixir
if :serverless in Atlas.capabilities(provider) do
  Atlas.run_job(provider: provider, endpoint: "...", input: %{...})
end
```

### Capability atoms

- `:spot` — interruptible/spot instances
- `:serverless` — `run_job/2` and friends
- `:network_volumes` — attach persistent volumes
- `:http_proxy` — provider terminates TLS on a `*.proxy…` hostname
- `:raw_tcp` — public IP + mapped TCP ports
- `:symmetric_ports` — `internal == external` port guarantee
- `:webhooks` — push completion callbacks
- `:global_networking` — private networking across datacenters

## Writing your own provider

```elixir
defmodule MyCloud.Provider do
  @behaviour Atlas.Provider

  @impl true
  def capabilities, do: [:http_proxy]

  @impl true
  def spawn_compute(%Atlas.Spec.ComputeRequest{} = req, ctx) do
    # translate `req` into your cloud's native payload,
    # POST it, normalize the response into %Atlas.Spec.Compute{}
  end

  # ... implement the other callbacks ...
end

# Use it
Atlas.spawn_compute(provider: MyCloud.Provider, gpu: :h100, image: "...")
```

Tests: `use Atlas.Test.ProviderConformance, provider: MyCloud.Provider,
reset: {MyCloud.TestHelpers, :reset_fixtures, []}` to inherit the shared
conformance suite.

## Auth primitives

`Atlas.Auth.Token` and `Atlas.Auth.SignedUrl` are exposed directly if you
want them without the rest of the orchestration layer:

```elixir
# Bearer token for API requests
mint = Atlas.Auth.Token.mint()
mint.token   # hand to browser once
mint.hash    # persist this

Atlas.Auth.Token.valid?(candidate, mint.hash)

# S3-style signed URL for <video src>, WebSocket, or any client that can't set headers
url =
  Atlas.Auth.SignedUrl.sign(
    "https://pod-id-8000.proxy.runpod.net/stream",
    secret: signing_secret,
    expires_in: 3600
  )

:ok = Atlas.Auth.SignedUrl.verify(url, secret: signing_secret)
```

## HTTP layer

Every provider uses `Req` under the hood:

- `Authorization: Bearer <api_key>` for REST and serverless runtime endpoints.
- `?api_key=<key>` query param for RunPod's legacy GraphQL (used only for the
  pricing catalog).
- `:retry :transient` with 3 retries by default.
- Telemetry: every request emits `[:atlas, <provider>, :request]` with
  `%{status: status}` measurements and `%{api: api, method: method, url: url}`
  metadata — wire into `:telemetry_metrics` or your own listener.

Override per call with `req_options:`:

```elixir
Atlas.spawn_compute(
  provider: :runpod,
  gpu: :h100,
  image: "...",
  req_options: [receive_timeout: 60_000, max_retries: 5]
)
```

## Roadmap

- **v0.1** — RunPod (full surface), Mock provider, orchestrator, auth.
- **v0.2** — Fly.io Machines, Lambda Labs.
- **v0.3** — Vast.ai.

All future providers will be additive; adding a provider never breaks
existing call sites.

## License

Apache-2.0. See `LICENSE`.
