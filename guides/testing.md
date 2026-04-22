# Testing

## The Mock provider

`ExAtlas.Providers.Mock` is an in-memory implementation of the full
`ExAtlas.Provider` behaviour. It runs synchronously — pods are
`:running` immediately after `spawn_compute/2`, jobs complete on the
next `get_job/2` call. Perfect for testing your own code that depends
on ExAtlas without hitting any network.

### Setup

```elixir
# test/test_helper.exs
ExUnit.start()
ExAtlas.Providers.Mock.ensure_started()
```

```elixir
# your test
defmodule MyApp.InferenceTest do
  use ExUnit.Case, async: false

  setup do
    ExAtlas.Providers.Mock.reset()
    :ok
  end

  test "my code handles a running pod" do
    {:ok, compute} = MyApp.start_session(user_id: 42)
    # my code calls ExAtlas internally; we point it at :mock via config
    assert compute.status == :running
    assert compute.provider == :mock
  end
end
```

Set the default provider per test suite:

```elixir
# config/test.exs
config :ex_atlas,
  default_provider: :mock,
  start_orchestrator: false
```

## Shared conformance suite

`ExAtlas.Test.ProviderConformance` is a `use` macro that runs the same
suite against any provider implementation, so every provider in the
library (and yours) exercises the same contract.

```elixir
defmodule MyCloud.ProviderTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: MyCloud.Provider,
    reset: {MyCloud.TestHelpers, :reset_bypass, []}
end
```

The `:reset` MFA is called before every test. Use it to:

- Reset Bypass expectations (for HTTP-based providers).
- Clear ETS or Mnesia fixtures.
- Rotate in-memory state.

## Integration tests against a live cloud

```elixir
defmodule ExAtlas.Providers.RunPodLiveTest do
  use ExUnit.Case, async: false

  @moduletag :live

  @tag timeout: 120_000
  test "spawn → wait-for-healthy → terminate on community RTX A4000" do
    {:ok, compute} =
      ExAtlas.spawn_compute(
        provider: :runpod,
        gpu: :a4000,
        image: "ubuntu:22.04",
        cloud_type: :community,
        ports: [{22, :tcp}]
      )

    on_exit(fn -> ExAtlas.terminate(compute.id, provider: :runpod) end)

    assert compute.status in [:provisioning, :running]
  end
end
```

Add `:live` to the excluded tags in `test_helper.exs`:

```elixir
ExUnit.start(exclude: [:live])
```

Run live tests explicitly:

```bash
RUNPOD_API_KEY=sk_... mix test --only live
```

## HTTP-level tests with Bypass

Mimic a provider's response without hitting the network:

```elixir
setup do
  bypass = Bypass.open()

  opts = [
    provider: :runpod,
    api_key: "test-key",
    base_url: "http://localhost:#{bypass.port}"
  ]

  {:ok, bypass: bypass, opts: opts}
end

test "spawn_compute POSTs /pods", %{bypass: bypass, opts: opts} do
  Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(raw)
    assert body["gpuTypeIds"] == ["NVIDIA H100 80GB HBM3"]

    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(
      201,
      Jason.encode!(%{"id" => "pod_abc", "desiredStatus" => "RUNNING"})
    )
  end)

  {:ok, compute} =
    ExAtlas.spawn_compute([gpu: :h100, image: "x"] ++ opts)

  assert compute.id == "pod_abc"
end
```

## Orchestrator tests

The orchestrator uses `Phoenix.PubSub` and `Registry`. Start supervised
children explicitly in `setup` so each test gets a fresh supervision
tree:

```elixir
setup do
  Application.put_env(:ex_atlas, :start_orchestrator, true)
  Application.put_env(:ex_atlas, :default_provider, :mock)
  ExAtlas.Providers.Mock.reset()

  start_supervised!({Registry, keys: :unique, name: ExAtlas.Orchestrator.ComputeRegistry})
  start_supervised!({DynamicSupervisor, name: ExAtlas.Orchestrator.ComputeSupervisor,
                                         strategy: :one_for_one})
  start_supervised!({Phoenix.PubSub, name: ExAtlas.PubSub})

  :ok
end
```

Follow project conventions:

- Use `Process.monitor/1` + `assert_receive {:DOWN, ...}` to wait for
  exits. Never `Process.sleep/1` to wait for processes to die.
- Use `start_supervised!/1` so ExUnit tears processes down between tests.
- Set `async: false` on suites that touch global application env.
