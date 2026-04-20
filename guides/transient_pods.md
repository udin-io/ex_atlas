# Transient per-user pods

This is the scenario Atlas was built for: a Phoenix app spawns a GPU pod
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
      Atlas.Orchestrator.spawn(
        gpu: :h100,
        image: "ghcr.io/me/my-inference-server:latest",
        ports: [{8000, :http}],
        auth: :bearer,
        user_id: socket.assigns.current_user.id,
        idle_ttl_ms: @idle_ttl_ms,
        name: "atlas-" <> to_string(socket.assigns.current_user.id)
      )

    Phoenix.PubSub.subscribe(Atlas.PubSub, "compute:" <> compute.id)

    {:ok,
     assign(socket,
       compute_id: compute.id,
       inference_url: hd(compute.ports).url,
       inference_token: compute.auth.token
     )}
  end

  def handle_event("ping", _, socket) do
    _ = Atlas.Orchestrator.touch(socket.assigns.compute_id)
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
    _ = Atlas.Orchestrator.stop_tracked(socket.assigns.compute_id)
    :ok
  end
end
```

### The inference server (inside the pod)

```elixir
defmodule InferenceServer do
  @moduledoc """
  Minimal Plug app running inside the RunPod pod. Rejects any request
  that doesn't carry the preshared key injected by Atlas.
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
`Atlas.Auth.SignedUrl`:

```elixir
# Generate a secret once per pod, inject it via env var (Atlas already does
# this when auth: :signed_url)
signed =
  Atlas.Auth.SignedUrl.sign(
    hd(compute.ports).url <> "/video/session-42.m3u8",
    secret: compute.auth.token,
    expires_in: 3600
  )

# In the LiveView:
<video src={signed} />
```

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
   and terminates them within `:reap_interval_ms`.
2. **LiveView disconnect without clean shutdown.** The `ComputeServer`'s
   idle timer fires regardless of what's talking to it.
3. **Provider API hiccups.** `terminate/2` errors are logged and broadcast
   as `{:terminate_failed, error}` but don't cause the server to hang.

## Pitfalls

- **Don't** share a single pod across users unless you've designed for
  isolation. The preshared-key model assumes one key per pod.
- **Don't** put the orchestrator in a cluster-shared PubSub — Atlas's
  PubSub is per-node. If you need cluster-wide visibility, subscribe
  from each node and reduce upstream.
- **Don't** spawn from a `Task.start/1` without supervision. If the task
  crashes between the provider call and the ComputeServer start, the pod
  is live on the cloud but untracked. The Reaper will eventually catch
  it, but your budget won't thank you.
