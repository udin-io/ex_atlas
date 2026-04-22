# Fly.io platform operations

ExAtlas's `ExAtlas.Fly.*` namespace provides first-class Fly.io platform
operations — independent of the GPU-compute provider pipeline. If you're
already using atlas for compute, Fly ops ride alongside with no extra
dependencies; if you're only using atlas for Fly ops, ignore the compute API.

This guide covers: installation, configuration, token lifecycle, discovering
apps, streaming logs, and streaming deploys.

## Installation

The fastest path is the Igniter installer:

```bash
mix igniter.install ex_atlas
# or, if atlas is already a dep:
mix ex_atlas.install
```

That writes a sensible `config :ex_atlas, :fly` block, creates the DETS storage
directory, and wires `phoenix_pubsub` if your app uses Phoenix.

Manual install — add to `mix.exs`:

```elixir
{:ex_atlas, "~> 0.2"}
```

ExAtlas is a regular OTP application — its supervision tree starts automatically.
The Fly sub-tree boots by default; disable with:

```elixir
config :ex_atlas, :fly, enabled: false
```

## Configuration

All options live under `config :ex_atlas, :fly`:

```elixir
config :ex_atlas, :fly,
  # Master switch (default: true). Set false to skip the whole Fly sub-tree.
  enabled: true,

  # Token storage (default: ExAtlas.Fly.TokenStorage.Dets)
  token_storage: ExAtlas.Fly.TokenStorage.Dets,
  storage_path: "priv/ex_atlas_fly",

  # Dispatcher mode (default: :registry)
  dispatcher: :registry,               # :registry | :phoenix_pubsub | {:mfa, {m,f,a}}
  pubsub: MyApp.PubSub,                # required when dispatcher: :phoenix_pubsub

  # Log endpoint + poll interval
  log_endpoint: "https://api.machines.dev/v1/apps",
  poll_interval_ms: 2_000,

  # Token resolution
  fly_config_file_enabled: true,       # read ~/.fly/config.yml when cache misses
  cli_timeout_ms: 15_000                # `fly tokens create` timeout
```

## Discovering apps

`discover_apps/1` scans `fly.toml` files at the project root and one level of
subdirectories (monorepo-friendly):

```elixir
ExAtlas.Fly.discover_apps("/path/to/project")
# => [{"my-api", "/path/to/project"}, {"my-web", "/path/to/project/web"}]
```

## Tailing logs

Subscribe from any process (LiveView, GenServer, plain pid):

```elixir
ExAtlas.Fly.subscribe_logs("my-api", "/path/to/project")

# In the subscriber:
def handle_info({:ex_atlas_fly_logs, "my-api", entries}, state) do
  # entries :: [ExAtlas.Fly.Logs.LogEntry.t()]
  ...
end
```

A single `Streamer` GenServer runs per app regardless of subscriber count.
When all subscribers disconnect, the streamer stops itself.

## Streaming deploys

Subscribe to a per-ticket deploy topic, then launch the deploy:

```elixir
ExAtlas.Fly.subscribe_deploy(ticket_id)
Task.start(fn ->
  ExAtlas.Fly.stream_deploy(project_path, "web", ticket_id)
end)

# In the subscriber:
def handle_info({:ex_atlas_fly_deploy, ^ticket_id, line}, state) do
  ...
end
```

The streamer enforces two timeouts:

* **Activity timer (5 min)** — resets on each chunk of output. Catches hung
  builders.
* **Absolute timer (30 min)** — never resets. Caps total deploy time.

`deploy/2` (non-streaming) is the simpler sync variant with a 15 min timeout
and the full output returned as a binary.

## Token lifecycle

`ExAtlas.Fly.Tokens` resolves tokens with this chain:

1. **ETS** — O(1) in-memory, 24 h TTL.
2. **`ExAtlas.Fly.TokenStorage`** — durable (DETS by default) so cached tokens
   survive restarts.
3. **`~/.fly/config.yml`** — the file `flyctl` writes after `fly auth login`.
4. **`fly tokens create readonly`** — CLI fallback with a 15 s timeout.
5. **Manual override** — a token the host set via
   `ExAtlas.Fly.Tokens.set_manual/2`.

Typical usage:

```elixir
{:ok, token} = ExAtlas.Fly.Tokens.get("my-api")

# Force re-acquisition (e.g. after a 401):
ExAtlas.Fly.Tokens.invalidate("my-api")

# Store a user-supplied override:
ExAtlas.Fly.Tokens.set_manual("my-api", "fo1_...")
```

`ExAtlas.Fly.Logs.Client.fetch_logs_with_retry/2` already invalidates on 401 and
retries once automatically.

## Pluggable token storage

For hosts that want tokens in a different store (a DB, a vault, etc.),
implement the `ExAtlas.Fly.TokenStorage` behaviour:

```elixir
defmodule MyApp.FlyTokenStorage do
  @behaviour ExAtlas.Fly.TokenStorage

  def child_spec(_opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def get(app, key), do: ...
  def put(app, key, record), do: ...
  def delete(app, key), do: ...
end

# config/config.exs
config :ex_atlas, :fly, token_storage: MyApp.FlyTokenStorage
```

ExAtlas will supervise your module in its Fly sub-tree.

## Dispatcher modes

ExAtlas cannot hard-depend on Phoenix, so logs/deploys are dispatched through
`ExAtlas.Fly.Dispatcher` with three modes:

* `:registry` (default) — atlas starts a `Registry` and uses `send/2`.
  Zero-deps. Best for non-Phoenix hosts.
* `:phoenix_pubsub` — uses `Phoenix.PubSub.broadcast/3`. Requires
  `phoenix_pubsub` in your deps and `config :ex_atlas, :fly, pubsub: MyApp.PubSub`.
  Best when you already have a cluster-wide PubSub.
* `{:mfa, {Mod, :fun, extra_args}}` — custom: on each dispatch atlas calls
  `apply(Mod, :fun, [topic, message | extra_args])`.

Subscriber message shapes are stable across modes.

## Testing

For unit tests, swap in the in-memory token store:

```elixir
defmodule MyTest do
  use ExUnit.Case

  setup do
    start_supervised!(ExAtlas.Fly.TokenStorage.Memory)
    Application.put_env(:ex_atlas, :fly, token_storage: ExAtlas.Fly.TokenStorage.Memory)
    :ok
  end
end
```

For HTTP-level tests, point `ExAtlas.Fly.Logs.Client` at a Bypass endpoint via
`base_url:`.
