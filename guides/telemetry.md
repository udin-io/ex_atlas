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
    [:ex_atlas, :runpod, :request],
    [:ex_atlas, :fly, :request],
    [:ex_atlas, :lambda_labs, :request],
    [:ex_atlas, :vast, :request]
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
