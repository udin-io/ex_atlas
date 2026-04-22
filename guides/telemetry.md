# Telemetry

Every HTTP request that ExAtlas makes emits a `:telemetry` event, so you
can wire the library into your existing metrics pipeline without writing
provider-specific code.

## Events

### `[:ex_atlas, <provider>, :request]`

Emitted after every REST, runtime, or GraphQL call.

**Measurements:**

| Key      | Type   | Value              |
| -------- | ------ | ------------------ |
| `status` | int    | HTTP status code   |

**Metadata:**

| Key      | Type   | Value                                       |
| -------- | ------ | ------------------------------------------- |
| `api`    | atom   | `:management` / `:runtime` / `:graphql`     |
| `method` | atom   | `:get` / `:post` / `:delete` / ...          |
| `url`    | string | Full request URL                            |

### `[:ex_atlas, :fly, :token, :acquire]` (span)

`:start` / `:stop` / `:exception` events around every
`ExAtlas.Fly.Tokens.get/1` call. Measure cache-hit rate, CLI acquisition
latency, and resolution failures.

**`:stop` metadata:**

| Key      | Type   | Value                                                                                   |
| -------- | ------ | --------------------------------------------------------------------------------------- |
| `app`    | string | Fly app name                                                                            |
| `source` | atom   | `:ets` / `:storage` / `:config` / `:cli` / `:manual` / `:none` (resolution failed) |

Measurements follow the standard `:telemetry.span/3` shape (`system_time`
on `:start`, `duration` + `monotonic_time` on `:stop`).

### `[:ex_atlas, :fly, :logs, :fetch]` (span)

`:start` / `:stop` / `:exception` around `ExAtlas.Fly.Logs.Client.fetch_logs/3`.
Emitted regardless of whether you call `fetch_logs/3` directly or go
through `fetch_logs_with_retry/2`.

**`:stop` metadata:**

| Key      | Type   | Value                        |
| -------- | ------ | ---------------------------- |
| `app`    | string | Fly app name                 |
| `status` | term   | `:ok` / `{:error, reason}`   |
| `count`  | int    | Number of entries returned   |

Log line content is never included in metadata — Fly log bodies may
contain bearer tokens, and we do not want them flowing into a metrics
pipeline.

### `[:ex_atlas, :fly, :deploy, :line]` and `[:ex_atlas, :fly, :deploy, :exit]`

Two events from `ExAtlas.Fly.Deploy.stream_deploy/3`:

- `:line` fires once per non-empty output line. `measurements: %{count: 1}`
  so a Counter reporter sums to total lines.
- `:exit` fires once when the deploy terminates.

**`:line` metadata:**

| Key         | Type   | Value                     |
| ----------- | ------ | ------------------------- |
| `ticket_id` | string | The deploy ticket ID      |

**`:exit` metadata:**

| Key         | Type   | Value                                                      |
| ----------- | ------ | ---------------------------------------------------------- |
| `ticket_id` | string | The deploy ticket ID                                       |
| `result`    | term   | `:ok` / `{:error, :timeout}` / `{:error, {:exit_code, N}}` |

Line **content** is deliberately excluded — Fly build output can contain
bearer tokens.

## Wiring into Logger

```elixir
:telemetry.attach(
  "atlas-http-logger",
  [:ex_atlas, :runpod, :request],
  fn _event, measurements, metadata, _config ->
    Logger.info(
      "ExAtlas → #{metadata.api} #{metadata.method} #{metadata.url} → #{measurements.status}"
    )
  end,
  nil
)
```

## Wiring into `:telemetry_metrics`

```elixir
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def metrics do
    [
      # Count requests grouped by provider + status class
      counter("atlas.runpod.request.count",
        event_name: [:ex_atlas, :runpod, :request],
        measurement: :status,
        tags: [:api, :method]
      ),

      # Watch error rates
      counter("atlas.runpod.request.errors",
        event_name: [:ex_atlas, :runpod, :request],
        measurement: :status,
        tags: [:api, :method],
        keep: fn metadata, measurements ->
          measurements.status >= 400
        end
      )
    ]
  end
end
```

Plug into Grafana / Prometheus / StatsD via whichever reporter you
prefer (`TelemetryMetricsPrometheus`, `TelemetryMetricsStatsd`, ...).

## Event attachment on application start

```elixir
defmodule MyApp.AtlasTelemetry do
  @events [
    # Provider HTTP requests
    [:ex_atlas, :runpod, :request],
    [:ex_atlas, :fly, :request],
    [:ex_atlas, :lambda_labs, :request],
    [:ex_atlas, :vast, :request],
    # Fly platform ops (spans emit :start + :stop + :exception)
    [:ex_atlas, :fly, :token, :acquire, :start],
    [:ex_atlas, :fly, :token, :acquire, :stop],
    [:ex_atlas, :fly, :logs, :fetch, :start],
    [:ex_atlas, :fly, :logs, :fetch, :stop],
    [:ex_atlas, :fly, :deploy, :line],
    [:ex_atlas, :fly, :deploy, :exit]
  ]

  def attach do
    :telemetry.attach_many(
      "atlas-telemetry",
      @events,
      &__MODULE__.handle/4,
      nil
    )
  end

  def handle(event, measurements, metadata, _config) do
    # Dispatch to your metrics system
  end
end

# lib/my_app/application.ex
def start(_type, _args) do
  MyApp.AtlasTelemetry.attach()
  # ...
end
```

## Orchestrator events

PubSub broadcasts from the orchestrator are covered in the README —
subscribe to `"compute:<id>"` on `ExAtlas.PubSub` for state-change
notifications. These are **PubSub messages**, not Telemetry events.

If you want Telemetry-style metrics for spawn/terminate counts, wrap
`ExAtlas.Orchestrator.spawn/1` in your own helper that emits a Telemetry
event alongside the call.
