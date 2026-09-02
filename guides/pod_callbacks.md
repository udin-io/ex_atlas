# Pod callbacks

RunPod has no API for pod logs — the console is the only place they exist, and
[it has been an open request upstream for years](https://github.com/runpod/runpod-python/issues/400).
Its REST API also reports no container state at all: a pod whose command has
exited keeps answering `desiredStatus: "RUNNING"` and keeps billing.

So for unattended work, the only party that knows what is happening inside the
container is the container. This guide is the supported way for it to say so.

## What you get

Turn it on and a running pod can:

  * report progress, which reaches your LiveView as a PubSub message;
  * stream log lines, which ExAtlas relays and **retains nowhere**;
  * declare its exit code before it goes, which turns
    `{:task, :completed}` from an inference into a fact and turns a crashed
    run into `{:task, {:failed, {:exit_code, 3}}}`.

It is strictly additive. A host that configures nothing behaves exactly as
before, down to the event sequence — see "Degraded mode" below.

## Setup

### 1. Configure a signing secret

```elixir
# config/runtime.exs
config :ex_atlas, :callback,
  secret: System.fetch_env!("ATLAS_CALLBACK_SECRET"),
  base_url: System.get_env("ATLAS_CALLBACK_BASE_URL")
```

Generate the secret with:

```elixir
:crypto.strong_rand_bytes(32) |> Base.encode64()
```

It must be at least 32 bytes and **identical on every node that can receive a
callback**. That is what lets you put a load balancer in front of the endpoint:
verification is one HMAC over data the token carries itself, with no table to
replicate.

`:base_url` is the default callback URL; you can also pass `callback:` per
call, which wins.

### 2. Start the orchestrator

```elixir
config :ex_atlas, start_orchestrator: true
```

The callback boundary routes through `ExAtlas.Orchestrator.ComputeRegistry` and
uses `ExAtlas.Callback.Limiter`, both of which live in that tree.

### 3. Mount the endpoint

```elixir
# lib/my_app_web/router.ex
scope "/atlas" do
  forward "/cb", ExAtlas.Callback.Plug
end
```

Three constraints, and each one matters:

  * **Outside the `:browser` pipeline.** A pod has no session and no CSRF
    token, and must not be handed one.
  * **Outside your own authentication plug.** The bearer token in the request
    *is* the authentication. Running it through a plug that expects a
    logged-in user only produces confusing redirects.
  * **Not through `Plug.Parsers`.** Its 8 MB default is the memory vector the
    plug exists to close. `ExAtlas.Callback.Plug` reads the body itself with a
    per-kind cap applied *before* anything is decoded.

A Phoenix `forward` runs after your endpoint's parsers, so put the forward in a
scope whose pipeline does not include them — or mount it in the endpoint ahead
of `Plug.Parsers`:

```elixir
# lib/my_app_web/endpoint.ex — before `plug Plug.Parsers`
plug :atlas_callback

defp atlas_callback(%{path_info: ["atlas", "cb" | rest]} = conn, _opts) do
  ExAtlas.Callback.Plug.call(%{conn | path_info: rest}, [])
end

defp atlas_callback(conn, _opts), do: conn
```

Not using Plug at all? `ExAtlas.Callback` is framework-free — `verify/1`,
`take/2`, `body_limit/1` and `ingest/3` are all you need for a hand-rolled
handler, and `:plug` stays an optional dependency you never pull in.

### 4. Spawn with a callback

```elixir
{:ok, pid, compute} =
  ExAtlas.Orchestrator.run_task(
    provider: :runpod,
    gpu: :rtx_4090,
    image: "ghcr.io/acme/trainer:latest",
    command: ["/app/train.sh"],
    max_runtime_ms: :timer.minutes(90),
    callback: "https://app.example.com/atlas/cb"
  )

Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)
```

The container gets three environment variables:

| variable                | meaning |
|-------------------------|---------|
| `ATLAS_CALLBACK_URL`    | base URL to POST to |
| `ATLAS_CALLBACK_TOKEN`  | bearer credential, scoped to this task |
| `ATLAS_TASK_ID`         | this task's id, for your own logging |

## The container side

`/finish` is already handled for you: the self-termination wrapper ExAtlas
generates POSTs the exit code from its `trap`, before deleting the pod. You
only write code for progress and logs.

```sh
#!/bin/sh
# report progress every 30s while training runs
report() {
  curl -sS -m 10 -X POST \
    -H "Authorization: Bearer $ATLAS_CALLBACK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"seq\":$1,\"pct\":$2,\"step\":\"$3\"}" \
    "$ATLAS_CALLBACK_URL/progress" || true
}

report 1 0 "starting"
python train.py | while IFS= read -r line; do
  printf '%s\n' "$line"
  curl -sS -m 10 -X POST \
    -H "Authorization: Bearer $ATLAS_CALLBACK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"lines":["%s"]}' "$line")" \
    "$ATLAS_CALLBACK_URL/logs" || true
done
```

Always `|| true` and always `-m`: a callback failure must never take the run
down with it, and a wedged connection must never delay the pod deleting itself.

Batch your log lines. `/logs` allows 6 requests per minute with a burst of 20,
so one request per line will be throttled on any real workload — send a
batch every few seconds instead.

## What you receive

Subscribe to `"compute:<id>"` and handle:

```elixir
def handle_info({:atlas_compute, _id, {:progress, payload}}, socket) do
  {:noreply, assign(socket, pct: payload["pct"], step: payload["step"])}
end

def handle_info({:atlas_compute, _id, {:log, payload}}, socket) do
  {:noreply, stream(socket, :log_lines, payload["lines"])}
end

def handle_info({:atlas_compute, _id, {:task_report, %{exit_code: code}}}, socket) do
  {:noreply, assign(socket, exit_code: code)}
end

def handle_info({:atlas_compute, _id, {:task, outcome}}, socket) do
  {:noreply, assign(socket, outcome: outcome)}
end
```

### ExAtlas retains zero log bytes

`/logs` is a bus, not a store — it broadcasts and forgets, exactly as
`ExAtlas.Fly.Logs.Streamer` already does with Fly log entries. There is no ring
buffer to size and no back-pressure to get wrong, and a host that subscribes to
nothing pays nothing. If you want history, keep it yourself, and put the
full post-mortem log in object storage alongside your artifacts.

## Limits and status codes

| path        | cap   | rate            |
|-------------|-------|-----------------|
| `/progress` | 8 KB  | 1/s, burst 5    |
| `/logs`     | 64 KB | 6/min, burst 20 |
| `/finish`   | 8 KB  | 1/min, burst 3  |

| code | meaning |
|------|---------|
| 202  | accepted |
| 400  | body was not a JSON object, or a finish carried no usable `exit_code` |
| 401  | signature bad, token expired, or the token does not cover this kind |
| 404  | not one of the three paths |
| 410  | nothing is tracking that task any more — stop reporting |
| 413  | body over the cap |
| 429  | over the rate budget; a `retry-after` header comes with it |

## `:completed` is now proven, not inferred

Without a callback, a `mode: :task` session ends when the resource disappears,
and `{:task, :completed}` means only "the container ended and the resource is
gone". The self-termination wrapper traps `EXIT`, so a crashed command cleans
up exactly like a successful one, and the exit code dies with the pod.

With a report recorded, the outcome comes from what the container said:

| observation                    | report            | outcome |
|--------------------------------|-------------------|---------|
| resource vanished              | none              | `:completed` (inferred) |
| resource vanished              | `exit_code: 0`    | `:completed` (proven) |
| resource vanished              | `exit_code: 3`    | `{:failed, {:exit_code, 3}}` |
| resource preempted             | `exit_code: 0`    | `:completed` |
| nothing, ever                  | none              | `:timed_out` at `:max_runtime_ms` |

That last-but-one row is the spot fix. On spot capacity a disappearance means
both "self-terminated fine" and "reclaimed by the provider", so
`on_failure: {:respawn, n}` can re-run work that already finished, on a meter.
A report is a marker written before the pod goes, so a compute that reported
`finish` is **never respawned**.

The honest limit: a pod preempted in the milliseconds between the POST and its
own `DELETE` still reads as completed. The work genuinely did finish, so that
is the right error to make.

### The report cannot extend the budget

`:max_runtime_ms` stays authoritative. A pod cannot buy itself more time by
staying quiet, and it cannot buy any by talking either: progress deliberately
does **not** call `touch/1`, because that would let a compromised pod defeat
its own idle TTL — and in `mode: :task` there is no idle clock to postpone
anyway, so the feature would carry risk exactly where it carries no benefit.

### When the report lands but the pod does not go

`self_terminate: false`, an image without `curl`, a `DELETE` that failed: the
report arrives and nothing ever disappears. `:finish_grace_ms` (default 60s) is
a one-shot armed by the first report; when it expires ExAtlas finishes on the
report and its own teardown issues the `DELETE` that stops the meter. Before
this existed, those tasks could only ever end as `:timed_out`, an hour later.

## Degraded mode: no publicly reachable host

If your app has no public URL, **omit `:callback`**. Everything reverts
precisely to the previous behaviour — a disappearance-derived `:completed`
plus the `:max_runtime_ms` deadline. Nothing half-configures, and nothing is
lost that was ever there.

What you must not do is point `:callback` at something the pod cannot reach.
That is the worst available outcome: the task looks healthy and you learn
nothing for the full hour of its budget. `ExAtlas.Callback.prepare/1` therefore
refuses a URL that is not absolute `https`, or that names a loopback,
RFC 1918, link-local or `.local`/`.internal` host, at spawn time and before the
provider is called — so the failure costs you nothing.

For local development, run a tunnel (cloudflared, ngrok, a Tailscale funnel)
and point `:base_url` at it. If you really want plain `http://localhost`, pass
`allow_insecure_callback: true` and accept that it only works when the pod can
route to you.

## Security model

The endpoint is internet-reachable and every byte on it comes from a container
you do not control. What the library does about that:

  * **A stateless signed token**, `Plug.Crypto.sign/4` over
    `%{task_id, kinds}`, verified in constant time. No hash table, so nothing
    to leak and nothing to replicate across nodes.
  * **Bound to a `task_id`, not a compute id.** RunPod assigns the compute id
    in the `POST /pods` response, so nothing could bind a token to it while the
    container env was still being built — and the task id survives an
    `on_failure: {:respawn, n}` swap, where a compute id would not.
  * **A different credential from `ATLAS_PRESHARED_KEY`.** That one is handed
    to a browser in the interactive flow, and a browser-held secret must never
    also authorize writing into your orchestrator.
  * **Expires with the work.** The token's max age is the task's budget plus
    a few minutes of slack, and it travels inside the token.
  * **Scoped by kind.** A token minted without `:finish` cannot report one.
  * **Capped before decode.** `read_body/2` carries the limit; the declared
    `content-length` is never consulted, because a hostile caller writes that
    header too.
  * **Rate limited in the library**, per task and per kind, because
    "put a limiter in front of it" is not an adequate answer for an endpoint
    the library tells you to expose.
  * **Never blocks the orchestrator.** Delivery is a `send`, never a
    `GenServer.call`, so a slow provider poll cannot become an HTTP timeout and
    an untrusted pod gets no lever on the tracker's mailbox.
  * **Nothing unbounded is kept.** One small `%{exit_code: n}` map per task, no
    log buffer, and rate-limit buckets swept on a timer.
  * **No atom is ever created from client input**, and no response body ever
    echoes the token.

Replay is deliberately not defended against with a nonce store. A replayed
`progress` is indistinguishable from a retry and is harmless — carry a `seq`
and let subscribers drop stale ones. A replayed `finish` is idempotent: the
first report wins, and it cannot buy another grace window. De-facto revocation
comes from the registry lookup: once the tracker is gone, every callback for
that task is a `410`.
