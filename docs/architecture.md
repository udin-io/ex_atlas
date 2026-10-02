# Architecture

This page maps ExAtlas's modules and processes as they exist on main after
PR #102, read from `lib/`. It exists so a new reader finds the orchestrator's
parts and their start order without reading 3,000 lines. The library has no
database and no web UI. It runs inside the host application's VM.

## Context

| Actor | Talks to ExAtlas by |
|---|---|
| Host Phoenix app | Calls `ExAtlas` and `ExAtlas.Orchestrator`; subscribes to `ExAtlas.PubSub` topics `"compute:<id>"` |
| RunPod | HTTPS through `Req` (`ExAtlas.Providers.RunPod.Client`): pods, catalog, billing, templates, volumes, endpoints, jobs |
| Lambda Cloud API v1 | HTTPS through `Req` (`ExAtlas.Providers.LambdaLabs.Client`): instance types, firewall rulesets, launch, get, list, terminate |
| Vast.ai API | HTTPS through `Req` (`ExAtlas.Providers.Vast.Client`): offer search, rent, get, list (v1, paged by `next_token`), stop and start (`PUT` state), charges (paged by `next_token`), destroy |
| A Vast instance | A marketplace host runs the image as a Docker container with its own entrypoint; Vast maps each container port to a random host port |
| A Lambda instance | cloud-init runs the `user_data` script ExAtlas wrote; it starts the container with `docker run`. With a callback, a `systemd-run` unit POSTs the container's exit code to `Callback.Plug` |
| A running pod | POSTs to the host through `ExAtlas.Callback.Plug` (progress, logs, finish) |
| Fly.io | `ExAtlas.Fly.*`: deploys, log streams, tokens |
| A shared store | Optional host `TrackingStore` implementation (a database) |

## Modules

| Layer | Modules |
|---|---|
| Facade | `ExAtlas` (`dispatch/3`, `dispatch_optional/3`), `ExAtlas.Config` (its `seal_credentials/1` wraps credentials), `ExAtlas.Secret`, `ExAtlas.Error` |
| Contract | `ExAtlas.Provider` (behaviour, optional callbacks) |
| Providers | `Providers.HTTP` (shared `Req` plumbing and the 429-only spawn retry), `Providers.RunPod` (with `Pods`, `Jobs`, `Catalog`, `Billing`, `Templates`, `NetworkVolumes`, `Endpoints`, `Translate`, `Client`), `Providers.LambdaLabs` (with `Client`, `Translate`, `Firewall`), `Providers.Vast` (with `Client`, `Translate`), `Providers.Shell` (POSIX quoting for the providers' scripts, and the trap that reports a command's exit and deletes its RunPod pod or Vast instance), `Providers.Mock`, the stub `Providers.Fly` (built with `Providers.Stub`) |
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
| `Orchestrator.TrackingStore.Ecto` | Functions, no process | Records as `term_to_binary` blobs in the host repo's `atlas_tracking_records`, decoded with `[:safe]`. `Ecto.Migration` creates the table |
| `Orchestrator.Supervisor` | `Supervisor` | The orchestrator's tree for a host to start after its repo; `children/0` is the one child list |
| `Orchestrator.Adopter` | Transient `Task` | At boot, re-creates trackers from the store, then releases the Reaper |
| `Orchestrator.RespawnCredentials` | Behaviour | Marks a host module whose function a record's `respawn_credentials:` may call |
| `Orchestrator.Reaper` | `GenServer` | Every `reap_interval_ms`, deletes untracked pods that carry the prefix and this node's owner |
| `Orchestrator.Ownership` | Functions | Reads and validates `reap_owner`; stamps it into pod names |
| `Orchestrator.ComputeRegistry`, `ComputeSupervisor` | `Registry`, `DynamicSupervisor` | Look up and supervise trackers |
| `Callback` | Functions | Routes a pod's report into a tracker through the `Registry` |

Start order (`ExAtlas.Orchestrator.Supervisor.children/0`): the tracking
store, `ComputeRegistry`, the `Task.Supervisor` for polls, `ComputeSupervisor`,
`Callback.Limiter`, `Phoenix.PubSub` (when loaded), `Reaper`, `Adopter`.
`start_orchestrator: true` starts that list in ExAtlas's own application;
`ExAtlas.Orchestrator.Supervisor` starts it in the host's tree instead.

## The orchestrator started after the host's repo

A store in the host's database (`TrackingStore.Ecto`, #120) is readable only
once the host's repo runs, and ExAtlas's application boots before the host's.
So the host sets `start_orchestrator: false` and starts
`ExAtlas.Orchestrator.Supervisor` after its repo:

```mermaid
sequenceDiagram
  participant Host as MyApp.Application
  participant Repo as MyApp.Repo
  participant Sup as ExAtlas.Orchestrator.Supervisor
  participant Store as TrackingStore.Ecto
  participant Adopter as Adopter
  participant Reaper as Reaper
  Host->>Repo: start (child 1)
  Host->>Sup: start (child 2), refuses when start_orchestrator is true
  Sup->>Store: start_link, raises ArgumentError when repo is unset
  Sup->>Reaper: start gated
  Sup->>Adopter: run
  Adopter->>Store: all()
  Store->>Repo: SELECT id, record FROM atlas_tracking_records
  Repo-->>Store: rows
  Store-->>Adopter: ok with records, or error when a row will not decode
  Adopter->>Reaper: adoption_complete, or adoption_failed
  Note over Host,Reaper: Shutdown runs in reverse, so the trackers stop while the Repo is up and persisted rows stay
```

```mermaid
classDiagram
  class TrackingStore {
    <<behaviour>>
    put(record) ok
    get(id) ok or error
    delete(id) ok
    all() ok or error
  }
  class Ecto {
    start_link(opts) ignore
    get(id) raises on a row that will not decode
    record column holds term_to_binary
  }
  class Migration {
    up(opts)
    down(opts)
    creates atlas_tracking_records
  }
  class Supervisor {
    start_link(opts)
    children()
  }
  class Application {
    orchestrator_children()
  }
  class Dets
  TrackingStore <|.. Ecto
  TrackingStore <|.. Dets
  Ecto ..> Migration : reads the table it creates
  Application ..> Supervisor : children() when start_orchestrator is true
```

When the store cannot answer, nothing is reaped: `all/0` returns an error and
the Adopter sends `adoption_failed`; `get/1` raises and the Reaper treats the
pod as ours; a tracker logs the raise and keeps its pod.

## The orchestrator at runtime

```mermaid
flowchart TD
  host["Host app"] -->|"spawn/1, run_task/1"| orc["Orchestrator"]
  orc -->|"ExAtlas.spawn_compute/1"| prov["Provider (RunPod, Lambda Labs)"]
  orc -->|"persist: true"| store[("TrackingStore<br/>DETS file or host repo")]
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
  cb -->|"progress, log, finish<br/>from the current attempt only"| cs
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

## A late report from a replaced pod

Every pod of a task shares its `task_id`; its token also signs its attempt
(#100). `ComputeServer` keeps the current attempt as the Registry value of
`{:callback, task_id}` and moves it before it rents a replacement. A report
already queued in the tracker carries its attempt, and the tracker drops it
when the attempt is stale. `Callback.take/2` spends a bucket keyed by task and
attempt before `ingest/3` runs, so the replaced pod's refused reports never
spend the replacement's budget (#107).

```mermaid
sequenceDiagram
  participant A as Pod A, attempt 0
  participant B as Pod B, attempt 1
  participant Pl as Callback.Plug
  participant L as Callback.take/2, Limiter
  participant Cb as Callback.ingest/3
  participant CS as ComputeServer
  participant P as Provider
  CS->>P: status poll
  P-->>CS: pod A gone, preempted
  CS->>CS: Registry value for the task becomes 1
  CS->>P: spawn_compute, callback attempt 1
  P-->>CS: pod B, its token signs attempt 1
  A->>Pl: POST /finish, token for attempt 0
  Pl->>L: take claims, :finish
  Note over L: spends the bucket of task and attempt 0
  Pl->>Cb: ingest claims
  Cb-->>Pl: not_tracked, 0 is not 1
  Pl-->>A: 410
  B->>Pl: POST /finish, token for attempt 1
  Pl->>L: take claims, :finish
  Note over L: bucket of task and attempt 1 is untouched
  Pl->>Cb: ingest claims
  Cb->>CS: atlas_callback finish, attempt 1
  Note over CS: a queued message with attempt 0 is dropped
```

A token minted by 0.8.0 has no attempt (#110). `ComputeServer` registers
`:claimless` instead of the attempt while its current pod holds such a token (a
task adopted from a 0.8.0 record, not respawned since), and `ingest/3` accepts
a claim-less token only against that value. The first respawn this version makes
registers the attempt, so the replaced pod's claim-less token gets 410. The
respawn also writes the attempt into the stored record's callback descriptor,
so a restart adopts the task as claim-bearing. The
tracker repeats the test for a claim-less report already in its mailbox. A task
that 0.8.0 itself respawned keeps two claim-less pods, which risk 49 records.

A node can die after the provider rents the replacement and before
`carry_record/3` moves the record to it (#114, risk 51). So the respawn first
writes `respawning: n` into the old record. The next boot's tracker counts
attempt `n` as spent and registers `:none`, which matches no token, until its
own respawn registers `n + 1`. It logs a warning naming the pod name; the
Reaper deletes the orphan, which no record names, when its provider is in
`:reap_providers`. `spawn/1` warns when a respawning task's provider is not
(#118); `:vast` is not by default.

The tracker checks a report against the attempt in its opts' callback
descriptor, which every respawn writes, while `respawns` counts the budget.
The two differ only in an interrupted adoption. If the first poll reads the
record's pod alive again (an outbid spot pod that won back its bid), the
tracker leaves `:none` and registers that pod's own attempt (#118). With
`status_poll_ms: false` no poll runs, and the pod's reports get 410 until the
deadline.

```mermaid
sequenceDiagram
  participant CS as ComputeServer, boot 1
  participant St as TrackingStore
  participant P as Provider
  participant B as Pod B, orphan, attempt 1
  participant CS2 as ComputeServer, adopted
  participant C as Pod C, attempt 2
  participant Cb as Callback.ingest/3
  P-->>CS: pod A preempted
  CS->>St: record A gets respawning 1
  CS->>P: spawn_compute, attempt 1
  P-->>B: rented
  Note over CS: node dies before carry_record
  St-->>CS2: record A, respawns 0, respawning 1
  Note over CS2: respawns 1, Registry value :none
  B->>Cb: POST /finish, attempt 1
  Cb-->>B: 410
  alt first poll reads pod A alive again
    CS2->>Cb: Registry value attempt 0, pod A's own
  end
  CS2->>P: spawn_compute, attempt 2
  P-->>C: rented
  CS2->>St: record C, respawns 2, respawning nil
  C->>Cb: POST /finish, attempt 2
  Cb->>CS2: accepted
```

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

On Vast (#116) step 4 reads `GET /api/v0/charges/` for the UTC days from the
pod's start. Vast takes no instance filter, so `Providers.Vast` pages through
the account's contract rows and keeps those whose `source` is
`instance-<id>`. The total is their `amount`; `gpu_usd` and `disk_usd` sum
the `gpu` and `disk` items.

```mermaid
sequenceDiagram
  participant CS as ComputeServer
  participant EA as ExAtlas.compute_spend
  participant V as Providers.Vast
  participant API as console.vast.ai
  CS->>EA: every reconcile_spend_ms, from: spawn time
  EA->>V: compute_spend(id, from:, ctx)
  V->>API: GET /api/v0/charges/ (day range, type instance)
  API-->>V: results page, next_token
  V->>API: next page until next_token is null
  V-->>CS: Spend total_usd, gpu_usd, disk_usd
  CS->>CS: the meter rises to the bill, never falls
```

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

## A Vast.ai spawn

Vast is a marketplace. `Providers.Vast` searches the on-demand offers and
rents the cheapest in the first hinted country, trying the next of three
only when Vast refused the rent. Added in #99. With `command:` the container
deletes its own instance when the command ends (#105). With `spot: true` the
search is `type: "bid"` and the rent carries `price`, the offer's `min_bid`
(#112); see "A Vast.ai spot respawn" below.

```mermaid
sequenceDiagram
  participant Host as Host app
  participant V as Providers.Vast
  participant T as Vast.Translate
  participant API as console.vast.ai
  participant VH as Vast host, Docker
  Host->>V: ExAtlas.spawn_compute(provider: :vast, gpu:, image:, env:, ports:)
  V->>T: launch_parts(request)
  T-->>V: env object, values as Secrets, -p flags, ATLAS_PORTS, auth handle
  V->>API: POST /api/v0/bundles/ (gpu_name in names, num_gpus, disk, ports, ondemand)
  API-->>V: offers, cheapest first, at most 64
  V->>T: pick(offers, region_hints)
  T-->>V: at most 3, first hinted country else anywhere
  V->>API: PUT /api/v0/asks/offer_id/ (runtype args, cancel_unavail, env, args), 429 retried, no redirect
  alt 2xx with new_contract
    API-->>V: new_contract
    V-->>Host: Compute provisioning, cost_per_hour, region
  else 4xx other than 401, 403, 408, 429: nothing rented
    API-->>V: error code
    V->>API: PUT the next offer
  else 5xx, timeout or no new_contract: may have rented
    V-->>Host: error, Vast's msg withheld, no retry
  end
  API->>VH: docker create and start the image, args to its entrypoint
  opt command with self_terminate true
    VH->>VH: sh -c runs the command, trap EXIT INT TERM
    VH->>API: DELETE /api/v0/instances/CONTAINER_ID/, CONTAINER_API_KEY on curl stdin
  end
  Host->>V: ExAtlas.get_compute(id)
  V->>API: GET /api/v0/instances/id/
  API-->>V: actual_status, public_ipaddr, ports map, extra_env
  V-->>Host: Compute running, http://ip:host_port, raw from an allow-list
  Host->>V: ExAtlas.terminate(id)
  V->>API: DELETE /api/v0/instances/id/
```

## A Vast.ai spot respawn

`spot: true` changes the search and the rent, and nothing in the orchestrator
(#112). An outbid instance reads `exited`; `UpstreamStatus.classify/2` maps
`:stopped` to `:preempted` for a spot task, and `ComputeServer.respawn/2`
rents a replacement before `release_old/1` destroys the old instance. A
`callback:`'s finish report keeps a task that finished from reading as outbid.

```mermaid
sequenceDiagram
  participant T as ComputeServer tracker
  participant V as Providers.Vast
  participant API as console.vast.ai
  T->>V: spawn_compute(spot true)
  V->>API: POST /api/v0/bundles/ type bid
  API-->>V: offers with min_bid
  V->>API: PUT /api/v0/asks/offer_id/ price = min_bid
  API-->>T: Compute provisioning, cost_per_hour = min_bid
  Note over API: another renter outbids the instance
  T->>V: get_compute(id)
  V->>API: GET /api/v0/instances/id/
  API-->>V: actual_status exited
  V-->>T: Compute stopped, classified preempted
  T->>V: spawn_compute(spot true), the replacement
  T->>V: terminate(old id), then {:respawned, new_id}
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
    start_command(request, delete)
    delete_request(url, key_var)
  }
  class Vast["Providers.Vast"] {
    capabilities: billing, raw_tcp, self_terminate, spot
    spawn_compute, get_compute, list_compute
    terminate, list_gpu_types
    stop, start
    compute_spend
  }
  class VastClient["Vast.Client"] {
    get(ctx, path)
    post(ctx, path, body, opts)
    put(ctx, path, body, opts)
    delete(ctx, path)
    list_instances(ctx)
    instance_charges(ctx, source, from_unix, to_unix)
  }
  class VastTranslate["Vast.Translate"] {
    launch_parts(request)
    offer_query(request)
    pick(offers, region_hints, spot)
    launch_body(request, parts)
    priced(body, request, offer)
    launched_compute(id, request, parts, offer)
    instance_to_compute(instance)
    state_body(state)
    charges_to_spend(rows, id, from, to)
    gpu_types(offers_by_gpu, bid_offers_by_gpu)
  }
  class RunPodTranslate["RunPod.Translate"]
  RunPodClient ..> HTTP
  LambdaClient ..> HTTP
  VastClient ..> HTTP
  Vast --> VastClient
  Vast --> VastTranslate
  VastTranslate ..> Auth
  VastTranslate ..> GpuCatalog
  VastTranslate ..> ComputeRequest
  VastTranslate ..> Shell
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
