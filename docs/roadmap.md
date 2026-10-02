# Roadmap

This page lists what ExAtlas has shipped and what comes next, built from the
merged PRs and open issues on `udin-io/ex_atlas` as of PR #123 (#120, the
Ecto tracking store, slice 1). It feeds the choice of the next
feature. Dates are merge dates.

## Next

Database tracking store (milestone 9). A `persist: true` task survives a
deploy today only when the DETS file sits on a mounted volume; on a Fly
machine with none, adoption finds nothing and the Reaper deletes the pods
(risk 3). We picked it because no roadmap item or open milestone is left, and
risk 3 is the open risk with the largest cost: hours of GPU work deleted on a
routine deploy. Three slices, each 4 to 8 hours:

| Slice | What it adds | Ticket |
|---|---|---|
| 1 | `TrackingStore.Ecto` in the host's repo, its migration module, and `ExAtlas.Orchestrator.Supervisor`, which the host starts after its repo | #120 |
| 2 | `mix ex_atlas.install --tracking-store ecto` writes the migration, config and child; `TrackingStoreConformance` ships in `lib`; the guides and risk 3 point at the Ecto store | not filed |
| 3 | Leases on a shared store: a live node adopts the records of an owner whose lease expired. Touches the Adopter and the Reaper, so it waits for #118 | not filed |

Vast.ai (#98) shipped with slice 4. Its templates, network volumes,
serverless, and SSH and Jupyter modes stay out of scope.

## In progress

| Feature | Ticket | State |
|---|---|---|
| Database tracking store, slice 1: `TrackingStore.Ecto`, its migration module and `ExAtlas.Orchestrator.Supervisor` | #120 | PR #123 open |
| Release 0.8.0 | #94 | PR #95 (merged): version bump, `guides/upgrading.md`, and a `"0.8.0"` step in `mix ex_atlas.upgrade`. The owner runs `mix hex.publish` and pushes the `v0.8.0` tag; no `v0.8.0` tag exists yet, and the Vast.ai entries sit under `CHANGELOG.md`'s Unreleased |

Fly retired GPU Machines on 2026-07-31, so `:fly` stays a compute stub;
Lambda Labs takes its place as the second provider, and Vast.ai the third.

## Shipped

| Feature | PRs | Merged |
|---|---|---|
| A respawning task warns when no Reaper covers its provider, and an adopted task's revived pod reports again (risk 51) | #119 (#118) | 2026-10-02 |
| Vast.ai provider (feature #98) | #102 (slice 1, #99): spawn by renting the cheapest on-demand offer, get, list, terminate, GPU types. #108 (slice 2, #105): `command:` with self-termination, `run_task/1`, `max_cost` and the Reaper. #113 (slice 3, #112): `spot: true` rents interruptible offers at `min_bid`, and an outbid instance respawns. #117 (slice 4, #116): `stop/2`, `start/2` and `compute_spend/3`, so `max_cost` reconciles against Vast's bill | 2026-10-02 |
| A late report from a replaced pod no longer ends the replacement (#100) | #101: the callback token signs the pod's attempt, and a stale report gets 410. #109 (#107): a replaced pod's refused reports spend their own rate budget. #111 (#110): a token with no attempt gets 410 once a respawn replaced the pod. #115 (#114): a pod rented by a respawn the node died in gets 410 after the next boot (risk 51) | 2026-10-02 |
| Lambda Labs provider (feature #83) | #89 (slice 1, #84): spawn through cloud-init, get, list, terminate, GPU types. #90 (slice 2, #85): `command:`, `run_task/1` ended by the host's report, the Reaper on Lambda. #91 (slice 3, #86): `ports:` open in Lambda's firewall. #97 (#96): an interactive session with a self-terminating command ends on the report | 2026-10-02 |
| Test reliability | #106 (#103, #104): the respawn billing test compares the bill within float rounding; the upgrade task tests run from a temp dir, so they pass in a checkout under a dot directory | 2026-10-02 |
| Docs build clean for 0.8.0 | #93 (#92): `bin/ci` fails on an ExDoc warning, every module grouped | 2026-10-02 |
| S3-compatible data staging (feature #26, milestone Data staging) | #75 (slice 1, #71): the `s3:` option and `Spec.Staging`. #77 (slice 2, #72): the guide and the tested entrypoint. #80 (slice 3, #73): presigned-URL mode. #78 (#76): credentials as `ExAtlas.Secret`. #81 (slice 4, #74): `persist: true` with `s3:`. #82 (#79): `env:` values as `ExAtlas.Secret`, names only in records. #88 (#87): `respawn_credentials:`, a host resolver re-supplies `s3:` and `env:` when an adopted task respawns | 2026-10-02 |
| Cost caps, `max_cost` (feature #28, milestone Provider resource management) | #67 (slice 1, #64): estimate, timer, events. #69 (slice 2, #65): a cap survives a restart. #70 (slice 3, #66): billing reconciliation every 15 min | 2026-10-01 |
| Provider resources through the public API (feature #27) | #60 network volumes, #61 templates, #62 spend, #63 endpoints | 2026-10-01 |
| CI hardening | #53 sobelow, #54 credo, #55 mix_audit weekly workflow, #50 flaky tests | 2026-10-01 |
| Multi-node orchestrator | #47 Reaper owner names, #48 graceful shutdown keeps persisted tasks, #49 shared store adopts only its own tasks | 2026-10-01 |
| RunPod API migration | #41 REST v1 to v2, #42 GPU catalog to v2 | 2026-09-30, 2026-10-01 |
| Release 0.7.0 | #44 | 2026-10-01 |
| Reaper re-adoption (`persist: true`) | #39 | 2026-09-23 |
| `await_ready/2` | #33 | 2026-09-02 |
| Pod callbacks: progress, logs, exit code | #32 | 2026-09-02 |
| Task mode, `run_task/1` | #31 | 2026-09-02 |
| Upstream status polling, spot preemption | #30 | 2026-08-29 |
| Provider options in the provider context | #29 | 2026-08-18 |
| Fly platform ops, token hardening, telemetry; releases 0.2 to 0.5; rename to `ex_atlas` | #9, #11, #12, #13, #15, #16, #17, #18, #19 | 2026-03-26 to 2026-04-22 |
| Docs: root `CLAUDE.md` | #68 | 2026-10-01 |

PRs #3, #4 and #7 (dashboard seed data and port) predate the rename and
survive only in history.

## Decided against

| Idea | Why not | Where |
|---|---|---|
| `max_cost` on `ComputeRequest` | The stateless `spawn_compute/1` would accept it and enforce nothing | #28 |
| Spend, endpoints and volume caps in the cost cap feature | One cap per tracked session only | #28 out of scope |
| A spend column on `ExAtlas.LiveDashboard.ComputePage` | Out of scope for #28 | #28 |
| Suppress the `hex.audit` advisories | Owner's decision 4 on #53 | `CLAUDE.md` |
