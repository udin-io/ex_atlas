# ExAtlas project overview

This is the hub for ExAtlas's source of truth. PR #70 (slice 3 and last of
feature #28, cost caps) creates it from the code on the branch and the
merged PRs, as the root `CLAUDE.md` asks. Read this page first, then follow
the link for the question you have. Every PR that changes behaviour,
structure, a risk or a decision updates the pages in the same PR.

## What ExAtlas is

ExAtlas is an Elixir library (`ex_atlas`, version 0.7.0 on Hex, 0.8.0
unreleased). It gives one API over GPU clouds, with RunPod as the only
complete provider, plus an opt-in orchestrator that tracks, polls and
deletes the pods you rent. It also carries Fly.io platform operations
(deploys, log streaming, tokens) that are independent of the compute path.

## Public API

| Surface | Module | What it does |
|---|---|---|
| Stateless compute | `ExAtlas` | `spawn_compute/1`, `get_compute/2`, `await_ready/2`, `list_compute/1`, `stop/2`, `start/2`, `terminate/2` |
| Serverless jobs | `ExAtlas` | `run_job/1`, `get_job/2`, `cancel_job/2`, `stream_job/2` |
| Catalog | `ExAtlas` | `list_gpu_types/1`, `capabilities/1` |
| Resources | `ExAtlas` | network volumes, templates, endpoints (list, get, create, delete), `compute_spend/2` |
| Provider contract | `ExAtlas.Provider` | Behaviour. Newer callbacks are optional; `ExAtlas` returns `:unsupported` when a provider lacks one |
| Providers | `ExAtlas.Providers.*` | `RunPod` (complete), `Mock` (tests, demos), `Fly`, `Vast`, `LambdaLabs` (stubs) |
| Orchestrator | `ExAtlas.Orchestrator` | `spawn/1`, `run_task/1`, `await_ready/2`, `touch/1`, `info/1`, `stop_tracked/1`, `list_ids/0`, `lookup/1` |
| Pod callbacks | `ExAtlas.Callback`, `ExAtlas.Callback.Plug` | A pod reports progress, logs and its exit code to the host |
| Auth | `ExAtlas.Auth.Token`, `ExAtlas.Auth.SignedUrl` | Bearer tokens and signed URLs for browser-to-pod traffic |
| Fly ops | `ExAtlas.Fly.*` | Deploys, log streaming, token lifecycle |

Every public function takes keyword options and returns `{:ok, struct}` or
`{:error, %ExAtlas.Error{}}`. Structs live in `ExAtlas.Spec.*`.

## The orchestrator

Off by default. `config :ex_atlas, start_orchestrator: true` starts a
`Registry`, a `DynamicSupervisor`, an optional `Phoenix.PubSub`, a `Reaper`
and, unless `tracking_store: false`, a tracking store and an `Adopter`.
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
| Orchestrator: polling, task mode, callbacks, adoption, multi-node | Shipped |
| Cost caps with billing reconciliation (feature #28) | Shipped in #70 (slices #67, #69, #70) |
| S3-compatible data staging (#26) | Slices 1 and 2 of 4: `s3:` injects `AWS_*` and `ATLAS_*` into RunPod pods (#75); a guide and a tested entrypoint script say what the container does with them (PR #77); credentials print redacted in crash reports (#78) |
| CI | Red at `hex.audit` by decision; see [risks.md](risks.md) |

## Pages

| Page | Question it answers | Status |
|---|---|---|
| [roadmap.md](roadmap.md) | What shipped, what is next? | Current to #78 |
| [architecture.md](architecture.md) | Which modules and processes exist? | Current to #78 |
| [risks.md](risks.md) | What could go wrong? | Current to #78 |
| [decisions.md](decisions.md) | Which choices shape the system? | Current to #78 |

There is no `uat.md`: the library has no user interface. The guides in
`guides/` and the live test (`mix test --only runpod_live`) cover
acceptance.

## Keeping it current

A merge is not finished until these pages describe `main` as it is. Move the
roadmap item, redraw a touched diagram, add or retire a risk, record the
decision. `README.md`, `guides/` and `CHANGELOG.md` stay in the same PR.
