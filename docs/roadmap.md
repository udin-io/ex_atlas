# Roadmap

This page lists what ExAtlas has shipped and what comes next, built from the
merged PRs and open issues on `udin-io/ex_atlas` as of PR #77 (slice 2 of
feature #26). It feeds the choice of the next feature. Dates are merge dates.

## Next

| Item | Ticket | State |
|---|---|---|
| Data staging slice 4: `persist: true` with `s3:` | #74 | Open, after #71 |
| Release 0.8.0 (owner ids, cost caps, `Timer` bound) | none filed | `CHANGELOG.md` lists it as Unreleased; `mix.exs` says 0.7.0 |

## In progress

| Feature | Slice | PR |
|---|---|---|
| S3-compatible data staging (feature #26, milestone Data staging) | Slice 1 (#71): the `s3:` option, `Spec.Staging`, `ComputeRequest.container_env/1`; `inspect(%Compute{})` hides `raw`; `env:` errors carry no values | #75 |
| | Slice 2 (#72): `guides/data_staging.md` and the tested `guides/scripts/atlas_entrypoint.sh` | #77 |
| | Slice 3 (#73): presigned-URL mode, `dataset_url` and `artifact_url`, and the entrypoint's `curl` branch | #80 |
| | Follow-up #76: credentials (`api_key:`, `req_options:` secrets, `s3:` keys, `compute.auth`) print as `#ExAtlas.Secret<redacted>` or not at all in crash reports | #78 |

## Shipped

| Feature | PRs | Merged |
|---|---|---|
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
