# Getting started

This guide walks through installing Atlas, configuring a provider, and
spawning your first GPU pod.

## 1. Add the dep

```elixir
# mix.exs
def deps do
  [
    {:atlas, "~> 0.1"}
  ]
end
```

For the orchestrator and LiveDashboard features, also add:

```elixir
{:phoenix_pubsub, "~> 2.1"},
{:phoenix_live_dashboard, "~> 0.8"}   # optional
```

Run `mix deps.get`.

## 2. Configure a provider

```elixir
# config/config.exs
config :atlas, default_provider: :runpod
config :atlas, :runpod, api_key: System.get_env("RUNPOD_API_KEY")

# Opt-in orchestrator (one-GenServer-per-pod supervision tree)
config :atlas, start_orchestrator: true
```

Resolution order for the API key:

1. Per-call `api_key:` option.
2. `config :atlas, :runpod, api_key: ...`.
3. `RUNPOD_API_KEY` env var.

## 3. Spawn a pod

```elixir
{:ok, compute} =
  Atlas.spawn_compute(
    gpu: :h100,
    image: "pytorch/pytorch:2.5.0-cuda12.1-cudnn9-runtime",
    ports: [{8000, :http}],
    cloud_type: :secure,
    auth: :bearer
  )

compute.id                # "pod_abc123"
compute.status            # :running
compute.ports             # [%{internal: 8000, external: nil, protocol: :http,
                          #    url: "https://pod_abc123-8000.proxy.runpod.net"}]
compute.auth.token        # preshared key, handed to the pod as ATLAS_PRESHARED_KEY env var
```

## 4. Terminate

```elixir
:ok = Atlas.terminate(compute.id)
```

## 5. Next steps

- [Transient per-user pods](transient_pods.md) — the production pattern.
- [Writing a provider](writing_a_provider.md) — implementing
  `Atlas.Provider` for your own cloud.
- [Telemetry](telemetry.md) — wiring the emitted events into Grafana,
  StatsD, etc.
- [Testing](testing.md) — conformance suite + Mock provider.
