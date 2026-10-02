# ExAtlas project overview

This is the hub for ExAtlas's source of truth. PR #70 (slice 3 and last of
feature #28, cost caps) creates it from the code on the branch and the
merged PRs, as the root `CLAUDE.md` asks. Read this page first, then follow
the link for the question you have. Every PR that changes behaviour,
structure, a risk or a decision updates the pages in the same PR.

## What ExAtlas is

ExAtlas is an Elixir library (`ex_atlas`, version 0.9.0). It gives one
API over GPU clouds, with RunPod, Lambda Labs and Vast.ai as complete
providers, plus an opt-in orchestrator that tracks, polls and deletes the
pods you rent. It also carries Fly.io platform operations (deploys, log
streaming, tokens) that are independent of the compute path.

## Public API

| Surface | Module | What it does |
|---|---|---|
| Stateless compute | `ExAtlas` | `spawn_compute/1`, `get_compute/2`, `await_ready/2`, `list_compute/1`, `stop/2`, `start/2`, `terminate/2` |
| Serverless jobs | `ExAtlas` | `run_job/1`, `get_job/2`, `cancel_job/2`, `stream_job/2` |
| Catalog | `ExAtlas` | `list_gpu_types/1`, `capabilities/1` |
| Resources | `ExAtlas` | network volumes, templates, endpoints (list, get, create, delete), `compute_spend/2` |
| Provider contract | `ExAtlas.Provider` | Behaviour. Newer callbacks are optional; `ExAtlas` returns `:unsupported` when a provider lacks one |
| Providers | `ExAtlas.Providers.*` | `RunPod` (complete), `LambdaLabs` (spawn, get, list, terminate, GPU types, `command:` and `run_task/1`), `Vast` (spawn, get, list, terminate, GPU types, `command:` and `run_task/1`, `spot: true` interruptible offers, `stop/2`, `start/2` and `compute_spend/3`), `Mock` (tests, demos), `Fly` (stub) |
| Orchestrator | `ExAtlas.Orchestrator` | `spawn/1`, `run_task/1`, `await_ready/2`, `touch/1`, `info/1`, `stop_tracked/1`, `list_ids/0`, `lookup/1` |
| Pod callbacks | `ExAtlas.Callback`, `ExAtlas.Callback.Plug` | A pod reports progress, logs and its exit code to the host |
| Auth | `ExAtlas.Auth.Token`, `ExAtlas.Auth.SignedUrl` | Bearer tokens and signed URLs for browser-to-pod traffic |
| Fly ops | `ExAtlas.Fly.*` | Deploys, log streaming, token lifecycle |

Every public function takes keyword options and returns `{:ok, struct}` or
`{:error, %ExAtlas.Error{}}`. Structs live in `ExAtlas.Spec.*`.

## The orchestrator

Off by default. `config :ex_atlas, start_orchestrator: true` starts a
`Registry`, a `DynamicSupervisor`, an optional `Phoenix.PubSub`, a `Reaper`
and, unless `tracking_store: false`, a tracking store and an `Adopter`. A
host whose tracking store is its own database (`TrackingStore.Ecto`) leaves
the flag false and starts `ExAtlas.Orchestrator.Supervisor` after its repo.
`spawn/1` rents a pod and starts one `ComputeServer` process for it. That
process:

- deletes the pod on any exit (idle TTL, `max_runtime_ms`, `max_cost`,
  `stop_tracked/1`);
- polls the provider to detect pod death and spot preemption;
- broadcasts state changes on the PubSub topic `"compute:<id>"`;
- with `mode: :task` (`run_task/1`), runs a container to completion;
- with `persist: true`, survives a deploy through the tracking store;
- with `max_cost: dollars`, deletes the pod when estimated spend reaches the
  cap, and checks the estimate against the provider's bill every 15 minutes.

See [architecture.md](architecture.md) for the modules and processes.

## Status

| Area | State |
|---|---|
| RunPod provider (REST v2, catalog, billing) | Shipped. REST v1 retires 2026-11-15; migrated in #41, #42 |
| Public API for network volumes, templates, endpoints, spend | Shipped (feature #27, PRs #60 to #63) |
| Orchestrator: polling, task mode, callbacks, adoption, multi-node | Shipped. A replaced pod's late report gets 410, a 0.8.0 pod's token with no attempt included once a respawn replaced it (#100, #110), and a pod a respawn rented as its node died (#114). A respawning spawn warns when no Reaper covers its provider, and an interrupted adoption's revived pod reports (#118). Records can live in the host's database with `TrackingStore.Ecto` (#120, slice 1 of milestone 9), set up by `mix ex_atlas.install --tracking-store ecto` (#128, slice 2). On that store a live node takes over a dead node's signed records once its owner lease expires (#132, slice 3), and deletes a dead owner's untracked pods once its lease stays expired for `:reap_dead_owner_after_ms` (#144, slice 1 of milestone 11). An adopted task takes its key and endpoint from config (#125), respawns only from a record the node signed (#131), and adopts an unsigned record only for a pod its Reaper would delete (#138). A Reaper that restarts after a crash reaps again (#122) |
| Cost caps with billing reconciliation (feature #28) | Shipped in #70 (slices #67, #69, #70) |
| S3-compatible data staging (#26) | Shipped in four slices: `s3:` injects `AWS_*` and `ATLAS_*` into RunPod pods (#75); a guide and a tested entrypoint script say what the container does with them (PR #77); credentials print redacted in crash reports (#78); presigned URLs put no storage key on the pod (#80); `persist: true` with `s3:` stores no credential, and an adopted task cannot respawn (#81); `env:` values print redacted and records keep names only (#82) |
| Lambda Labs provider (feature #83) | Shipped in three slices. Slice 1 (#84, PR #89): a container runs through cloud-init `user_data`; get, list, terminate and `list_gpu_types/1`. Slice 3 (#86, PR #91): one firewall ruleset per instance opens its `ports:`. Slice 2 (#85, PR #90): `command:`, `run_task/1` ended by the host's finish report, the Reaper. #96 (PR #97): an interactive session with a self-terminating command ends on the report too |
| Vast.ai provider (feature #98) | Shipped in four slices. Slice 1 (#99, PR #102): rent the cheapest on-demand offer; get, list, terminate and `list_gpu_types/1`. Slice 2 (#105, PR #108): `command:` with self-termination, `run_task/1`, `max_cost` and the Reaper (with `reap_providers: [:vast]`). Slice 3 (#112, PR #113): `spot: true` rents interruptible offers, and an outbid instance respawns. Slice 4 (#116, PR #117): `stop/2`, `start/2` and `compute_spend/3`, so `max_cost` reconciles against Vast's bill |
| Release 0.8.0 (#94) | `mix ex_atlas.upgrade` has a `"0.8.0"` step that edits no file: it warns about each module with `@behaviour ExAtlas.Provider` and about `start_orchestrator: true` with no `:reap_owner`. `guides/upgrading.md` covers the six breaking changes. Published to Hex on 2026-10-02, from tag `v0.8.0` on `939cf2e` |
| Release 0.9.0 (#141) | Merged in #142: `mix ex_atlas.upgrade`'s `"0.9.0"` step edits no file and names a missing callback secret; `guides/upgrading.md` covers the five changes. The owner publishes and tags `v0.9.0` |
| CI | Red at `hex.audit` by decision; see [risks.md](risks.md) |

## Pages

| Page | Question it answers | Status |
|---|---|---|
| [roadmap.md](roadmap.md) | What shipped, what is next? | Current to #140 |
| [architecture.md](architecture.md) | Which modules and processes exist? | Current to #140 |
| [risks.md](risks.md) | What could go wrong? | Current to #140 |
| [decisions.md](decisions.md) | Which choices shape the system? | Current to #140 |

There is no `uat.md`: the library has no user interface. The guides in
`guides/` and the live tests (`mix test --only runpod_live`,
`mix test --only lambda_live`, `mix test --only vast_live`) cover
acceptance.

## Keeping it current

A merge is not finished until these pages describe `main` as it is. Move the
roadmap item, redraw a touched diagram, add or retire a risk, record the
decision. `README.md`, `guides/` and `CHANGELOG.md` stay in the same PR.
