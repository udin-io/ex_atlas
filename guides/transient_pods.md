# Transient per-user pods

This is the scenario ExAtlas was built for: a Phoenix app spawns a GPU pod
per active user, the user's browser talks directly to the pod, and the
pod is reaped when the user leaves.

## Why not proxy through the Phoenix app?

For real-time workloads (video inference, audio transcription, generative
streaming) the extra hop doubles latency and forces your Phoenix node to
carry per-user bandwidth. Handing the browser a URL that points straight
at the pod keeps Phoenix out of the data path.

## The flow

```
Browser                 Phoenix (Fly.io)                 RunPod pod
   │                          │                             │
   │    1. open session       │                             │
   ├─────────────────────────►│                             │
   │                          │   2. spawn_compute          │
   │                          ├────────────────────────────►│
   │                          │   (inject ATLAS_PRESHARED_KEY env var)
   │   3. {url, token}        │◄────────────────────────────┤
   │◄─────────────────────────┤                             │
   │                                                        │
   │   4. inference over HTTPS with Authorization: Bearer   │
   ├───────────────────────────────────────────────────────►│
   │                                                        │
   │           5. touch heartbeats                          │
   ├─────────────────────────►│                             │
   │                          │                             │
   │   6. idle_ttl_ms passes with no heartbeat              │
   │                          │   7. terminate              │
   │                          ├────────────────────────────►│
```

## Implementation

### The LiveView

```elixir
defmodule MyAppWeb.InferenceLive do
  use MyAppWeb, :live_view

  @idle_ttl_ms 15 * 60_000  # 15 minutes

  def mount(_params, _session, socket) do
    {:ok, _pid, compute} =
      ExAtlas.Orchestrator.spawn(
        gpu: :h100,
        image: "ghcr.io/me/my-inference-server:latest",
        ports: [{8000, :http}],
        auth: :bearer,
        user_id: socket.assigns.current_user.id,
        idle_ttl_ms: @idle_ttl_ms,
        name: "atlas-" <> to_string(socket.assigns.current_user.id)
      )

    Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> compute.id)

    {:ok,
     assign(socket,
       compute_id: compute.id,
       inference_url: hd(compute.ports).url,
       inference_token: compute.auth.token
     )}
  end

  def handle_event("ping", _, socket) do
    _ = ExAtlas.Orchestrator.touch(socket.assigns.compute_id)
    {:noreply, socket}
  end

  def handle_info({:atlas_compute, _id, {:status, :terminated}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Inference session ended")
     |> redirect(to: ~p"/")}
  end

  def handle_info({:atlas_compute, _id, _other}, socket), do: {:noreply, socket}

  def terminate(_reason, socket) do
    # LiveView process is dying; cut the pod short to save $
    _ = ExAtlas.Orchestrator.stop_tracked(socket.assigns.compute_id)
    :ok
  end
end
```

### The inference server (inside the pod)

```elixir
defmodule InferenceServer do
  @moduledoc """
  Minimal Plug app running inside the RunPod pod. Rejects any request
  that doesn't carry the preshared key injected by ExAtlas.
  """

  import Plug.Conn

  @behaviour Plug

  def init(_), do: []

  def call(conn, _) do
    if authenticated?(conn) do
      handle(conn)
    else
      conn |> put_status(401) |> send_resp(401, "unauthorized") |> halt()
    end
  end

  defp authenticated?(conn) do
    preshared = System.fetch_env!("ATLAS_PRESHARED_KEY")

    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Plug.Crypto.secure_compare(token, preshared)
      _ -> false
    end
  end

  defp handle(conn) do
    # ... your inference logic ...
  end
end
```

### Signed URLs for media streams

`<video src>` can't send an `Authorization` header. Use
`ExAtlas.Auth.SignedUrl`:

```elixir
# Generate a secret once per pod, inject it via env var (ExAtlas already does
# this when auth: :signed_url)
signed =
  ExAtlas.Auth.SignedUrl.sign(
    hd(compute.ports).url <> "/video/session-42.m3u8",
    secret: compute.auth.token,
    expires_in: 3600
  )

# In the LiveView:
<video src={signed} />
```

## Waiting until the pod is usable

`spawn/1` returns when RunPod accepts the rental, which is 30–90 seconds
(sometimes minutes, on a cold image) before anything in the pod answers a
request. A LiveView should not block on that — subscribe, render "starting…",
and react to `{:status, :running}` as the snippet above does.

Everything that is *not* a LiveView should use `await_ready/2`:

```elixir
# Tracked: rides the tracker's existing status poll, so this costs the
# provider no extra requests.
case ExAtlas.Orchestrator.await_ready(compute.id, timeout_ms: 120_000) do
  {:ok, ready}                 -> warm_up(hd(ready.ports).url)
  {:error, {:dead, reason, _}} -> {:error, reason}
  {:error, {:timeout, last}}   -> abandon_or_wait_longer(last)
end

# Untracked (a bare ExAtlas.spawn_compute/1, a script, a mix task): polls
# get_compute/2 itself. Needs the provider opts; takes :poll_interval_ms.
ExAtlas.await_ready(compute.id, provider: :runpod, timeout_ms: 120_000)
```

Three properties worth knowing:

- **A failed poll never resolves the wait.** A 5xx, a rate limit or a socket
  error means "we could not tell", so the wait backs off and keeps going to
  its timeout. Only an answer that says failed, stopped, terminated or gone
  ends it early — the same rule the poller itself works under.
- **Timing out terminates nothing.** You get the last observed `Compute` back
  and decide; `{:error, {:timeout, last}}` and `{:error, {:dead, reason, _}}`
  are deliberately different answers to deliberately different questions.
- **It follows a respawn.** With `on_failure: {:respawn, n}` a preempted pod is
  replaced rather than ended, and the wait resolves on the replacement — on the
  original deadline, so a preemption cannot buy the pod a fresh budget.

The tracked wait runs in the calling process and consumes that pod's
`{:atlas_compute, id, _}` messages while it waits, so call it from a task
(`start_async/3`, `Task.async/1`, an Oban worker) rather than from a process
that is itself subscribed. And because it listens to the tracker rather than
the provider, it is only as timely as `:status_poll_ms` — with
`status_poll_ms: false` nothing observes upstream at all, so use
`ExAtlas.await_ready/2` with provider opts if you want your own poll.

## Choosing `idle_ttl_ms`

- Too short: users blink and the pod dies. Bad UX, repeated cold starts
  (and RunPod boot times on some GPUs can be 30-90 seconds).
- Too long: abandoned sessions burn $/hour until the reaper catches them.

A good default is **2–3× your expected user-idle window**. If your app
sends a `:ping` every 30 seconds and users normally stay active,
`idle_ttl_ms: 120_000` is reasonable. For exploratory/bursty tools
(generative art, Jupyter-like), go higher (10–15 min).

## What the orchestrator protects against

1. **Node crashes.** When the Phoenix node restarts, the Reaper finds
   orphan pods (live on RunPod, not tracked locally, name prefix matches)
   and terminates them within `:reap_interval_ms` — once they are past
   `:reap_grace_ms`, which spares resources whose tracker is still being
   registered.
2. **LiveView disconnect without clean shutdown.** The `ComputeServer`'s
   idle timer fires regardless of what's talking to it.
3. **Provider API hiccups.** `terminate/2` errors are logged and broadcast
   as `{:terminate_failed, error}` but don't cause the server to hang.
4. **The pod dying without telling you.** Every `:status_poll_ms` the
   `ComputeServer` asks the provider whether the pod is still there, so a
   host failure, a crash-looping image or a reclaimed spot instance ends the
   session with a real reason instead of leaving the UI showing a pod that
   no longer exists.

## When the pod dies underneath you

The idle timer measures your users; it says nothing about the cloud. Handle
the upstream events too, or a dead pod stays "connected" in the UI until the
idle TTL finally fires:

```elixir
# Anything the poller reports as dead ends the session.
def handle_info({:atlas_compute, _id, {:status, status}}, socket)
    when status in [:failed, :stopped, :vanished, :preempted] do
  {:noreply,
   socket
   |> put_flash(:error, "Your GPU session ended unexpectedly (#{status}).")
   |> redirect(to: ~p"/")}
end

# The poll failed, not the pod. Say "reconnecting", don't end the session.
def handle_info({:atlas_compute, _id, {:poll_failed, _error}}, socket) do
  {:noreply, assign(socket, provider_reachable?: false)}
end
```

`:preempted` only ever appears for pods you spawned with `spot: true`. RunPod
publishes no preemption signal — no field, no event, no status — so ExAtlas
infers it: an interruptible pod that stopped or vanished without you asking
was almost certainly reclaimed. Treat it as a strong hint, not a fact.

### Spot capacity for unattended work

Interactive sessions should not run on spot: the user is sitting there, and
the replacement pod has a different URL and token. For batch work that
checkpoints, opt into replacement:

```elixir
ExAtlas.Orchestrator.spawn(
  gpu: :h100,
  image: "ghcr.io/me/trainer:latest",
  spot: true,
  status_poll_ms: 30_000,
  on_failure: {:respawn, 3},
  name: "atlas-train-" <> run_id
)
```

The tracking process survives the swap and re-keys itself under the new pod
id, so `touch/1`, `info/1` and teardown keep working. Subscribers get
`{:respawned, new_id}` on the *original* topic — your cue to subscribe to the
new topic and read the replacement:

```elixir
def handle_info({:atlas_compute, _old_id, {:respawned, new_id}}, socket) do
  Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:" <> new_id)
  {:ok, %{compute: compute}} = ExAtlas.Orchestrator.info(new_id)

  {:noreply, assign(socket, compute: compute)}
end
```

The event deliberately carries the id alone. `compute.auth` holds a live
bearer token, and broadcasting it would put a credential on a topic every
subscriber — on every node — can read.

## Batch work: `run_task/1`

Everything above assumes a user is sitting at the other end of the pod. When
nobody is — a training run, a batch render, an eval sweep — the idle-TTL model
is actively wrong: the default 30-minute TTL would kill a 90-minute run unless
you faked heartbeats for it.

`ExAtlas.Orchestrator.run_task/1` is the same tracker in `mode: :task`:

```elixir
{:ok, _pid, compute} =
  ExAtlas.Orchestrator.run_task(
    gpu: :rtx_4090,
    image: "ghcr.io/me/trainer:latest",
    command: ["/app/train.sh", "--epochs", "3"],
    name: "atlas-task-" <> run_id,
    max_runtime_ms: :timer.minutes(90),
    ready_timeout_ms: :timer.minutes(10)
  )
```

No heartbeat clock is started, `touch/1` has nothing to postpone, and the
session ends on one of three events:

```elixir
def handle_info({:atlas_compute, _id, {:task, :completed}}, socket) do
  # The container ended and the pod is gone. See the caveat below.
  {:noreply, assign(socket, state: :finished)}
end

def handle_info({:atlas_compute, _id, {:task, :timed_out}}, socket) do
  # Hit max_runtime_ms. The pod has been deleted.
  {:noreply, assign(socket, state: :timed_out)}
end

def handle_info({:atlas_compute, _id, {:task, {:failed, reason}}}, socket) do
  # :never_ready | :preempted | :terminated | :failed
  {:noreply, assign(socket, state: {:failed, reason})}
end
```

The usual `{:terminating, _}` / `{:status, :terminated}` pair still follows,
so a handler that only cares about "is it over?" needs no changes.

### The pod must end itself

This is the part that surprises people. RunPod's REST API reports no container
state at all — the `Pod` schema has no `runtime` object, no `currentStatus`
and no exit code, and `desiredStatus` is only `RUNNING | EXITED | TERMINATED`,
a *desired* state that changes when somebody asks it to. So when your command
exits, **the pod stays `RUNNING` and keeps billing**, and no amount of polling
will tell you the work is done.

So `:self_terminate` (on by default whenever you pass `:command`) wraps your
command in a shell that deletes the pod when it ends:

```sh
atlas_self_terminate() {
  curl -sS -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" \
    "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID"
}
trap atlas_self_terminate EXIT INT TERM
/app/train.sh --epochs 3
```

`RUNPOD_POD_ID` and the pod-scoped `RUNPOD_API_KEY` are injected by RunPod, so
nothing of yours travels to the pod. `trap … EXIT` fires on a crash and on
SIGTERM/SIGINT as well as on a clean exit. The tracker sees the resulting 404
and reports `{:task, :completed}`.

Your image needs a shell and `curl`. If it has neither, pass
`self_terminate: false` — the task will then always end at `:max_runtime_ms`
and report `:timed_out`, which is honest but wasteful, so size the deadline
accordingly.

### Why `:max_runtime_ms` is not optional

Self-termination cannot run when there is nothing left in the container to run
it: a SIGKILL, an OOM kill, a wedged process, an image that never pulled.
Those pods stay `RUNNING` forever. The deadline is the only thing that ends
them, which is why `run_task/1` supplies one (60 minutes) even if you don't.

It is **wall clock from spawn**, not compute time and not time since the pod
became ready: billing starts when the pod is rented, and a slow image pull is
exactly the unbounded cost worth capping. `:ready_timeout_ms` exists so a pull
that will never succeed fails in minutes instead of eating the whole budget.

The deadline also **carries across a respawn**. If a spot task is preempted at
minute 80 of a 90-minute budget, the replacement gets the remaining 10, not a
fresh 90 — otherwise `on_failure: {:respawn, 3}` would let "90 minutes" spend
six hours.

### `:completed` does not mean "succeeded"

It means *the container ended and the pod is gone*. Because the trap fires on
a crash too, a failed run and a successful one produce the same 404, and the
exit code dies with the pod. If you need the difference, report it from inside
the container before it exits — write a status file to a network volume, or
call a webhook in your app:

```sh
/app/train.sh --epochs 3 && curl -fsS -X POST https://myapp.example/tasks/$RUN_ID/ok \
  || curl -fsS -X POST https://myapp.example/tasks/$RUN_ID/failed
```

### Spot tasks are ambiguous on purpose

With `spot: true`, a vanished pod is reported as `:preempted` — and a
self-terminating container also makes the pod vanish. From the API the two are
indistinguishable, so `on_failure: {:respawn, n}` on a spot task can re-run
work that had already finished. Use respawn only where a re-run is harmless
(checkpoint-resuming training, the case it was built for). The carried
deadline caps the damage either way.

### Choosing a poll interval

RunPod's management API documents no rate limits whatsoever, so the 60s
default is deliberately conservative — one request per pod per minute. Go
faster (10–30s) when a minute of wasted GPU time matters more than request
volume; remember the cost scales with the number of live pods, not with the
interval alone. Polls back off exponentially while the provider is erroring,
so an outage doesn't turn into a retry storm.

## Pitfalls

- **Don't** share a single pod across users unless you've designed for
  isolation. The preshared-key model assumes one key per pod.
- **Don't** put the orchestrator in a cluster-shared PubSub — ExAtlas's
  PubSub is per-node. If you need cluster-wide visibility, subscribe
  from each node and reduce upstream.
- **Don't** spawn from a `Task.start/1` without supervision. If the task
  crashes between the provider call and the ComputeServer start, the pod
  is live on the cloud but untracked. The Reaper will eventually catch
  it, but your budget won't thank you.
