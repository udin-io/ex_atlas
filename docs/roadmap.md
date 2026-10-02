# Roadmap

This page lists what ExAtlas has shipped and what comes next, built from the
merged PRs and open issues on `udin-io/ex_atlas` as of PR #88 (#87, the
respawn after adoption). It feeds the choice of the next feature. Dates are merge dates.

## Next

| Item | Ticket | State |
|---|---|---|
| Release 0.8.0 (owner ids, cost caps, `Timer` bound) | none filed | `CHANGELOG.md` lists it as Unreleased; `mix.exs` says 0.7.0 |
| Docs build clean for 0.8.0 | #92 | PR #93: `bin/ci` fails on an ExDoc warning, every module grouped |

## In progress

| Feature | Slice | State |
|---|---|---|
| Lambda Labs provider (#83) | 1, #84: spawn a container through cloud-init, get, list, terminate, GPU types | Merged in #89, 2026-10-02 |
| Lambda Labs provider (#83) | 2, #85: `command:`, `run_task/1` ended by the host's report, the Reaper on Lambda | PR #90 |
| Lambda Labs provider (#83) | 3, #86: open `ports:` in Lambda's firewall | Merged in #91, 2026-10-02 |

Fly retired GPU Machines on 2026-07-31, so `:fly` stays a compute stub;
Lambda Labs takes its place as the second provider.

## Shipped

| Feature | PRs | Merged |
|---|---|---|
| S3-compatible data staging (feature #26, milestone Data staging) | #75 (slice 1, #71): the `s3:` option and `Spec.Staging`. #77 (slice 2, #72): the guide and the tested entrypoint. #80 (slice 3, #73): presigned-URL mode. #78 (#76): credentials as `ExAtlas.Secret`. #81 (slice 4, #74): `persist: true` with `s3:`. #82 (#79): `env:` values as `ExAtlas.Secret`, names only in records. #88 (#87): `respawn_credentials:`, a host resolver re-supplies `s3:` and `env:` when an adopted task respawns | 2026-10-02 (#88 on merge) |
| Cost caps, `max_cost` (feature #28, milestone Provider resource management) | #67 (slice 1, #64): estimate, timer, events. #69 (slice 2, #65): a cap survives a restart. #70 (slice 3, #66): billing reconciliation every 15 min | 2026-10-01 (#70 on merge) |
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
