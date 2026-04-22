# Writing a provider

ExAtlas providers are plain Elixir modules that implement the
`ExAtlas.Provider` behaviour. They're free to use any HTTP client, any auth
scheme, and any data model internally — the only contract is the
callbacks and the normalized structs they return.

## Minimum viable provider

```elixir
defmodule MyCloud.Provider do
  @behaviour ExAtlas.Provider

  alias ExAtlas.Spec

  @impl true
  def capabilities, do: [:http_proxy]

  @impl true
  def spawn_compute(%Spec.ComputeRequest{} = req, ctx) do
    client = build_client(ctx)

    body = %{
      # translate ExAtlas.Spec.ComputeRequest into MyCloud's native shape
      "gpu" => translate_gpu(req.gpu),
      "image" => req.image,
      "ports" => Enum.map(req.ports, fn {p, _} -> p end)
    }

    case Req.post(client, url: "/instances", json: body) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, to_compute(body)}

      {:ok, %{status: status, body: body}} ->
        {:error, ExAtlas.Error.from_response(status, body, :mycloud)}

      {:error, err} ->
        {:error, ExAtlas.Error.new(:transport, provider: :mycloud, raw: err)}
    end
  end

  # ... implement the rest of the callbacks ...

  defp build_client(%{api_key: key}) do
    Req.new(
      base_url: "https://api.mycloud.example.com/v1",
      auth: {:bearer, key},
      retry: :transient,
      receive_timeout: 30_000
    )
  end

  defp translate_gpu(canonical) do
    case ExAtlas.Spec.GpuCatalog.for_provider(canonical, :mycloud) do
      {:ok, id} -> id
      {:error, _} -> raise "no mapping for #{inspect(canonical)}"
    end
  end

  defp to_compute(body) do
    %Spec.Compute{
      id: body["id"],
      provider: :mycloud,
      status: body["status"] |> to_atom_status(),
      ports: translate_ports(body),
      raw: body
    }
  end
end
```

## Use it right away

The top-level `ExAtlas.*` functions accept modules directly — no
registration required:

```elixir
ExAtlas.spawn_compute(
  provider: MyCloud.Provider,
  gpu: :h100,
  image: "..."
)
```

If you want the short atom form (`provider: :mycloud`) for your own app,
alias it in your own wrapper module or add it to your host app's
`ExAtlas.Config` mapping.

## Callbacks breakdown

### Required

- **`capabilities/0`** — list of atoms. Callers use this to branch on
  optional features. Be honest: declaring `:serverless` when you don't
  implement `run_job/2` will surface as runtime errors, not compile errors.
- **`spawn_compute/2`** — must return `{:ok, %ExAtlas.Spec.Compute{}}` or
  `{:error, %ExAtlas.Error{} | term()}`.
- **`get_compute/2`** — fetch by id, return normalized struct.
- **`list_compute/2`** — honor at minimum `:status` and `:name` filters.
- **`terminate/2`** — return `:ok` on success, `{:error, ...}` on failure.
- **`stop/2` / `start/2`** — can return `{:error, :unsupported}` if your
  cloud doesn't distinguish pause from destroy.

### Optional (declared via `@optional_callbacks`)

- `run_job/2`, `get_job/2`, `cancel_job/2`, `stream_job/2` — skip if you
  don't implement serverless.
- `list_gpu_types/1` — skip if your cloud has no pricing catalog.

## Register GPU mappings

Add your provider to `ExAtlas.Spec.GpuCatalog`'s `@providers` map so
callers can use the canonical atoms (`:h100`, `:a100_80g`, ...) against
your cloud. This is the only code change inside the ExAtlas library itself
that a new provider typically requires.

## Use the shared conformance suite

```elixir
# test/my_cloud/provider_test.exs
defmodule MyCloud.ProviderTest do
  use ExUnit.Case, async: false

  use ExAtlas.Test.ProviderConformance,
    provider: MyCloud.Provider,
    reset: {MyCloud.TestHelpers, :reset_bypass, []}
end
```

The suite asserts:

- `capabilities/0` returns a list of atoms.
- `spawn_compute/1 → get_compute/1 → terminate/1` round-trips.
- `spawn_compute/1` with `auth: :bearer` returns a token handle.
- `list_compute/0` returns a list.

If your provider passes these, it's wired correctly.

## Error normalization

Use `ExAtlas.Error.from_response/3` to translate HTTP responses into the
canonical shape. Callers that pattern-match on `kind:` atoms will then
work against your provider the same way they work against RunPod.

## `:raw` field

Every normalized struct has a `:raw` field. Put the provider's full
response body there so callers can reach for fields you haven't
normalized yet — this is the forward-compatibility lever.

## Reference implementations

- `ExAtlas.Providers.RunPod` (+ `ExAtlas.Providers.RunPod.Translate`) — full
  production provider against REST + GraphQL.
- `ExAtlas.Providers.Mock` — minimal in-memory implementation, good for
  understanding the callback shapes.
- `ExAtlas.Providers.Stub` — the macro used by Fly/Lambda/Vast placeholders
  to reserve names before their real implementations land.
