# Architecture

This page maps ExAtlas's modules and processes as they exist on the branch of
PR #70, read from `lib/`. It exists so a new reader finds the orchestrator's
parts and their start order without reading 3,000 lines. The library has no
database and no web UI. It runs inside the host application's VM.

## Context

| Actor | Talks to ExAtlas by |
|---|---|
| Host Phoenix app | Calls `ExAtlas` and `ExAtlas.Orchestrator`; subscribes to `ExAtlas.PubSub` topics `"compute:<id>"` |
| RunPod | HTTPS through `Req` (`ExAtlas.Providers.RunPod.Client`): pods, catalog, billing, templates, volumes, endpoints, jobs |
| Lambda Cloud API v1 | HTTPS through `Req` (`ExAtlas.Providers.LambdaLabs.Client`): instance types, firewall rulesets, launch, get, list, terminate |
| A Lambda instance | cloud-init runs the `user_data` script ExAtlas wrote; it starts the container with `docker run`. With a callback, a `systemd-run` unit POSTs the container's exit code to `Callback.Plug` |
| A running pod | POSTs to the host through `ExAtlas.Callback.Plug` (progress, logs, finish) |
| Fly.io | `ExAtlas.Fly.*`: deploys, log streams, tokens |
| A shared store | Optional host `TrackingStore` implementation (a database) |

## Modules

| Layer | Modules |
|---|---|
| Facade | `ExAtlas` (`dispatch/3`, `dispatch_optional/3`), `ExAtlas.Config` (its `seal_credentials/1` wraps credentials), `ExAtlas.Secret`, `ExAtlas.Error` |
| Contract | `ExAtlas.Provider` (behaviour, optional callbacks) |
| Providers | `Providers.HTTP` (shared `Req` plumbing and the 429-only spawn retry), `Providers.RunPod` (with `Pods`, `Jobs`, `Catalog`, `Billing`, `Templates`, `NetworkVolumes`, `Endpoints`, `Translate`, `Client`), `Providers.LambdaLabs` (with `Client`, `Translate`, `Firewall`), `Providers.Shell` (POSIX quoting for both providers' scripts), `Providers.Mock`, stubs `Providers.Fly`, `Providers.Vast` (built with `Providers.Stub`) |
| Specs | `ExAtlas.Spec.*`: `ComputeRequest` (its `container_env/1` is the env every provider sends), `Staging` (the `s3:` option), `Compute`, `Spend`, `Template`, `NetworkVolume`, `Endpoint`, `Job`, `GpuType` and the request structs |
| Callback | `ExAtlas.Callback`, `Callback.Plug`, `Callback.Token`, `Callback.Limiter` |
| Auth | `ExAtlas.Auth` (the env and handle for each `auth:` scheme, shared by providers), `ExAtlas.Auth.Token`, `ExAtlas.Auth.SignedUrl` |
| Orchestrator | listed below |
| Fly ops | `ExAtlas.Fly`, `Fly.Deploy`, `Fly.Logs.*`, `Fly.Tokens.*`, `Fly.TokenStorage` (DETS) |
| Dashboard | `ExAtlas.LiveDashboard.ComputePage` |
| Installer | `mix ex_atlas.install`, `mix ex_atlas.upgrade` (Igniter; the 0.8.0 step only warns, see `guides/upgrading.md`) |

## Orchestrator parts

| Module | Kind | Job |
|---|---|---|
| `Orchestrator` | Functions | Public API. `spawn/1` validates options, stamps the owner, rents the pod, checks the price, persists, starts a tracker |
| `Orchestrator.ComputeServer` | One `GenServer` per pod, `restart: :temporary` | Idle TTL, status poll, `max_runtime_ms`, `ready_timeout_ms`, `max_cost`, billing reconcile, respawn, teardown in `terminate/2` |
| `Orchestrator.CostMeter` | Pure | Spend estimate, cap timer delay, `reconcile/3`, `new_pod/2`, `resume/4` |
| `Orchestrator.TaskOutcome` | Pure | Decides whether an observation ends a `mode: :task` session, and how |
| `Orchestrator.UpstreamStatus` | Pure | Classifies a provider answer: `{:alive, _}`, `{:dead, reason, _}`, `{:poll_failed, _}` |
| `Orchestrator.Timer` | Constants | `max_ms/0` (4,294,967,295) and `option_type/0` for every timer option |
| `Orchestrator.Events` | Functions | PubSub broadcasts `{:atlas_compute, id, event}` |
| `Orchestrator.TrackingStore` | Behaviour | `put/1`, `get/1`, `delete/1`, `all/0`, `child_spec/1`. Default `TrackingStore.Dets` |
| `Orchestrator.Adopter` | Transient `Task` | At boot, re-creates trackers from the store, then releases the Reaper |
| `Orchestrator.RespawnCredentials` | Behaviour | Marks a host module whose function a record's `respawn_credentials:` may call |
| `Orchestrator.Reaper` | `GenServer` | Every `reap_interval_ms`, deletes untracked pods that carry the prefix and this node's owner |
| `Orchestrator.Ownership` | Functions | Reads and validates `reap_owner`; stamps it into pod names |
| `Orchestrator.ComputeRegistry`, `ComputeSupervisor` | `Registry`, `DynamicSupervisor` | Look up and supervise trackers |
| `Callback` | Functions | Routes a pod's report into a tracker through the `Registry` |

Start order (`ExAtlas.Application.orchestrator_children/0`): the tracking
store, `ComputeRegistry`, the `Task.Supervisor` for polls, `ComputeSupervisor`,
`Callback.Limiter`, `Phoenix.PubSub` (when loaded), `Reaper`, `Adopter`.

## The orchestrator at runtime

```mermaid
flowchart TD
  host["Host app"] -->|"spawn/1, run_task/1"| orc["Orchestrator"]
  orc -->|"ExAtlas.spawn_compute/1"| prov["Provider (RunPod, Lambda Labs)"]
  orc -->|"persist: true"| store[("TrackingStore")]
  orc -->|"start tracker"| cs["ComputeServer"]
  cs -->|"status poll"| us["UpstreamStatus"]
  us --> prov
  us -->|"observation"| to["TaskOutcome"]
  cs --> cm["CostMeter"]
  cm -->|"timer at cap"| cs
  cs -->|"every reconcile_spend_ms:<br/>ExAtlas.compute_spend/2"| prov
  cs -->|"record spend"| store
  cs -->|"events"| ev["Events / PubSub"]
  ev --> host
  cs -->|"terminate/2: ExAtlas.terminate/2<br/>after idle TTL, max_runtime_ms, cost cap,<br/>or finish report + finish_grace_ms"| prov
  pod["RunPod container, or Lambda host unit"] -->|"Callback.Plug"| cb["Callback"]
  cb -->|"progress, log, finish"| cs
  boot["Boot"] --> ad["Adopter"]
  ad -->|"all/0"| store
  ad -->|"start with adopted record"| cs
  cs -->|"respawn after adoption:<br/>apply(m, f, args ++ [info])"| res["Host resolver<br/>respawn_credentials"]
  ad -->|"adoption_complete / adoption_failed"| rp["Reaper"]
  rp -->|"list, delete untracked"| prov
  rp -.->|"ours = Registry or store"| store
```

## What a respawn after adoption does

A tracking record holds `:not_stored` in place of `s3:` credentials and
`env:` values. When an adopted `on_failure: {:respawn, n}` task is
preempted, `ComputeServer.spawn_replacement/1` asks the host's
`respawn_credentials:` resolver for them (#87). The record's tuple comes
first, then `config :ex_atlas, :orchestrator, respawn_credentials:`. A task
that never restarted holds its own values and calls no resolver.

```mermaid
sequenceDiagram
  participant Ad as Adopter
  participant St as TrackingStore
  participant CS as ComputeServer
  participant R as Host resolver, an MFA
  participant P as Provider
  participant Host as Host app, PubSub
  Ad->>St: all/0 at boot
  St-->>Ad: record, s3 and env values not_stored, respawn_credentials MFA
  Ad->>CS: start with adopted record
  CS->>P: status poll
  P-->>CS: pod gone, preempted
  CS->>R: apply(m, f, args ++ [info]) in a task, at most 30 s
  R-->>CS: ok, s3 and env
  CS->>CS: validate as ComputeRequest.new/1 does, seal as Secrets
  CS->>P: spawn_compute with resolved s3 and env
  P-->>CS: replacement compute
  CS->>St: carry record, markers kept, no value written
  CS-->>Host: respawned, new id
  alt no resolver, error, raise, throw, exit or timeout
  CS-->>Host: respawn_failed with a validation error naming the resolver
  end
```

The resolved values live in the tracker's opts, so a second respawn in the
same VM reuses them. The next restart calls the resolver again.

## What a cost cap does

1. `spawn/1` refuses a provider that reports no price: it deletes the pod and
   returns `:unsupported`.
2. `CostMeter` multiplies `cost_per_hour` by elapsed time; `ComputeServer`
   arms one timer for the moment spend reaches `max_cost`.
3. A status poll with a new price re-arms the timer.
4. Every `reconcile_spend_ms`, `ComputeServer` runs `ExAtlas.compute_spend/2`
   on the current pod in a task. A bill above the estimate raises spend and
   re-arms the timer. It broadcasts `{:spend_reconciled, map}` with
   `estimated_usd`, `billed_usd` and `spent_usd`.
5. A respawn calls `CostMeter.new_pod/2`; a bill queued for the replaced pod
   is ignored.

## A Lambda Labs spawn

Lambda rents VMs. `Providers.LambdaLabs` reads the catalog for price and
capacity, then launches with a cloud-init script that runs the container.
The tags let any node rebuild the `Compute` with no local state. Added in
#89. A spawn with `ports:` also creates a firewall ruleset for the instance
(#86); `us-south-1` and a spawn with no ports skip it.

```mermaid
sequenceDiagram
  participant Host as Host app
  participant LL as Providers.LambdaLabs
  participant T as LambdaLabs.Translate
  participant FW as LambdaLabs.Firewall
  participant L as Lambda Cloud API v1
  participant VM as Instance, cloud-init
  Host->>LL: ExAtlas.spawn_compute(provider: :lambda_labs, image:, env:, ports:)
  LL->>T: launch_parts(request, now)
  T-->>LL: user_data as a Secret, atlas tags, auth handle
  LL->>L: GET /instance-types
  L-->>LL: price_cents_per_hour, regions_with_capacity_available
  LL->>FW: open(ctx, request, rules, region)
  FW->>L: GET /firewall-rulesets
  FW->>L: DELETE each atlas- ruleset with no instance, 5 minutes old, at most 10
  FW->>L: POST /firewall-rulesets, one tcp rule per port
  L-->>FW: ruleset id
  LL->>L: POST /instance-operations/launch with firewall_rulesets (retried on 429 only)
  L-->>LL: instance_ids
  alt launch fails
    LL->>FW: delete(ruleset id)
    FW->>L: DELETE /firewall-rulesets/id
  end
  LL-->>Host: Compute provisioning, cost_per_hour, region
  L->>VM: boot, then cloud-init runs user_data as root
  VM->>VM: docker run --gpus all -p 8000:8000 -e NAME image
  Host->>LL: ExAtlas.get_compute(id)
  LL->>L: GET /instances/id
  L-->>LL: status, ip, tags
  LL-->>Host: Compute running, ports with ip URLs
  Host->>LL: ExAtlas.terminate(id)
  LL->>FW: find(ctx, id)
  FW->>L: GET /firewall-rulesets
  LL->>L: POST /instance-operations/terminate
  LL->>FW: delete(ruleset id)
  FW->>L: DELETE /firewall-rulesets/id (the in-use refusal is ignored)
```

## A Lambda task, ended by the host's report

A Lambda instance holds no key that can delete it. With `command:` and a
callback, the host script starts the container, then a transient
`systemd-run` unit that waits on it and POSTs its exit code. The tracker
finishes on the report and terminates the instance. Without a callback,
`self_terminate: true` is `:validation` before any request. Added in #85.

An interactive `Orchestrator.spawn/1` session with the same `command:` and
callback ends the same way, since #96: `finish_grace_ms` after the report it
broadcasts `{:terminating, :finished}` instead of a task outcome, and
`touch/1` does not postpone it. With `self_terminate: false` the report is
announced and the session runs on.

```mermaid
sequenceDiagram
  participant Host as Host app
  participant O as Orchestrator.run_task
  participant LL as Providers.LambdaLabs
  participant CS as ComputeServer
  participant VM as Instance user_data
  participant U as systemd unit atlas-finish
  participant C as Container
  participant CB as Callback.Plug
  Host->>O: run_task(provider: :lambda_labs, command:, callback:)
  O->>LL: spawn_compute with ATLAS_CALLBACK_* in the env
  LL-->>O: Compute provisioning
  O->>CS: start tracker
  VM->>VM: mktemp, printf the unit script (URL, token)
  VM->>C: docker run --detach image command (exports in a subshell)
  VM->>U: systemd-run /bin/bash unit-script docker
  U->>U: rm its own script
  U->>C: docker wait atlas
  C-->>U: exit code, or 125 when the container never ran
  U->>CB: POST /finish exit_code, token on curl stdin
  CB->>CS: finish report
  CS->>CS: finish_grace_ms, then task completed or failed
  Note over CS: interactive spawn/1: terminating finished
  CS->>LL: terminate(id)
  CS-->>Host: task outcome event
```

```mermaid
classDiagram
  class HTTP["Providers.HTTP"] {
    bearer(ctx, provider, hint)
    attach_telemetry(req, prefix, api)
    merge_user_options(req, ctx)
    handle_response(result, expected, provider)
    retry_rate_limited(request, response)
  }
  class RunPodClient["RunPod.Client"]
  class LambdaLabs["Providers.LambdaLabs"] {
    spawn_compute, get_compute, list_compute
    terminate, list_gpu_types
    stop and start return unsupported
  }
  class LambdaClient["LambdaLabs.Client"] {
    get(ctx, path)
    post(ctx, path, body, opts)
    delete(ctx, path)
    list_all(ctx, path)
  }
  class LambdaFirewall["LambdaLabs.Firewall"] {
    open(ctx, request, rules, region)
    attach(body, ruleset_id)
    find(ctx, instance_id)
    delete(ctx, ruleset_id)
  }
  class LambdaTranslate["LambdaLabs.Translate"] {
    launch_parts(request, now)
    launch_body(request, parts, type, region, ssh_key)
    firewall_rules(request)
    instance_type(request, types)
    region(type, entry, hints)
    instance_to_compute(instance, auth)
    gpu_types(types)
  }
  class Auth["ExAtlas.Auth"] {
    for_scheme(scheme)
  }
  class Shell["Providers.Shell"] {
    quote_arg(value)
    join(command)
  }
  class RunPodTranslate["RunPod.Translate"]
  RunPodClient ..> HTTP
  LambdaClient ..> HTTP
  LambdaLabs --> LambdaClient
  LambdaLabs --> LambdaTranslate
  LambdaLabs --> LambdaFirewall
  LambdaFirewall --> LambdaClient
  LambdaTranslate ..> Auth
  LambdaTranslate ..> GpuCatalog
  LambdaTranslate ..> ComputeRequest
  LambdaTranslate ..> Shell
  RunPodTranslate ..> Shell
```
