# Roadmap

This page lists what ExAtlas has shipped and what comes next, built from the
merged PRs and open issues on `udin-io/ex_atlas` as of PR #160 (milestone
13). It feeds the choice of the next feature. Dates are merge dates.

## Next

No milestone is open. By the rule below, the next pick is rank 2, risk 16:
after a respawn and a restart the cost cap undercounts. Rank 1, risk 4, is
retired for an unreadable store by milestone 13 (#153, PRs #157 and #160); its
config faults stay.

The rule, as for milestones 9, 11 and 13: when no roadmap item or open
milestone is left, we take the open risk with the largest cost that a
feature can retire. We left out risk 2 and 15 (cowlib, waits on an upstream
release), every risk only the owner's live tests settle (1, 14, 19, 20, 33,
44, 52, 56, 58, 61; the Lambda and Vast live runs are deferred by the owner),
and the part of risk 6 the owner accepted (replay and a held row lock, decision
on PR #149). Ranking, read from `docs/risks.md` at PR #152:

| Rank | Risk | What it costs when it fires | What bounds it | A feature can retire it? |
|---|---|---|---|---|
| 1 | 4 | A node reaps nothing for a whole boot; untracked pods bill at GPU rates | The next boot | Yes for the unreadable store (retry the read). A missing or duplicate `reap_owner` is a config fault that stays |
| 2 | 16 | After a respawn and a restart the cap undercounts, so spend passes `max_cost` by the earlier pods' bill | One pod's spend per restart | Yes: a version 4 record with the current pod's starting spend, and a new column in host stores |
| 3 | 11, 57, 62 | An exited pod or Vast instance bills its disk; the Reaper only lists `:provisioning` and `:running` | Nothing, until someone deletes it; a disk bill, not a GPU bill | Yes: reap stopped pods past a longer grace |
| 4 | 3 | A DETS store on a Fly machine with no volume comes up empty each deploy, and the Reaper deletes the pods | One config line, `mix ex_atlas.install --tracking-store ecto` | Partly: a boot warning, not a new default |
| 5 | 5 | Unclustered machines on one account delete each other's pods | One config line; the 0.8.0 upgrader warns | No: the fix is config |
| 6 | 7, 34, 36, 47, 54 | A pod bills after its container exits or its host never answers | `max_runtime_ms`, on by default in `run_task/1` | Defaults already on |

## In progress

| Feature | Ticket | State |
|---|---|---|
| Release 0.10.0 (milestone 12) | #151 | Merged in #152: version bump, CHANGELOG release section, `guides/upgrading.md` and README pins. The owner publishes and tags `v0.10.0` |

Fly retired GPU Machines on 2026-07-31, so `:fly` stays a compute stub;
Lambda Labs takes its place as the second provider, and Vast.ai the third.

## Shipped

| Feature | PRs | Merged |
|---|---|---|
| Reaper survives a failed store read (milestone 13, risk 4) | #157 (#154): a DETS store that lost records keeps saying so, and a closed DETS table shields its pods. #160 (#155): the supervised Adopter retries an unreadable store and the Reaper reaps once it reads; every adoption leaves a live tracker's record alone. Closes parent #153 and milestone 13 | 2026-10-03 |
| Dead owner's pods, slice 2 (milestone 11, risk 6) | #150 (#145): a record a dead owner still holds, and no node takes over, no longer shields its pod; the Reaper deletes the record, then the pod. Closes parent #143 and milestone 11 | 2026-10-03 |
| Dead owner's pods, slices 1 and 3 (milestone 11, risk 6) | #147 (#144): the Reaper deletes a dead owner's untracked pods. #149 (#148): lease rows signed (migration step 3), dead-owner deletion on by default | 2026-10-03 |
| Release 0.9.0 (milestone 10) | #142 (#141): version bump, the 0.9.0 section of `guides/upgrading.md`, and a `"0.9.0"` step in `mix ex_atlas.upgrade`. The owner publishes to Hex and pushes tag `v0.9.0` | 2026-10-02 |
| Release 0.8.0 (milestone 7) | #95 (#94): version bump, `guides/upgrading.md`, and a `"0.8.0"` step in `mix ex_atlas.upgrade`. Published to Hex from tag `v0.8.0` on `939cf2e` | 2026-10-02 |
| An unsigned tracking record adopts only a pod this node's Reaper would delete (milestone 9, risk 64) | #140 (#138) | 2026-10-02 |
| A forged tracking record no longer steers an adopted task's calls, and an adopted task respawns only from a record this node signed (milestone 9, risk 63) | #130 (#125), #135 (#131) | 2026-10-02 |
| No pod `env` in `Compute.raw`, `Endpoint.raw`, `Template.raw` or `Error.raw` (risks 18, 32) | #127 (#126), #134 (#133), #137 (#136) | 2026-10-02 |
| A Reaper that restarts after a crash reaps again (risk 4) | #124 (#122) | 2026-10-02 |
| Database tracking store, slice 3 (milestone 9) | #139 (#132): owner leases on the Ecto store, so a live node adopts a dead node's signed records | 2026-10-02 |
| Database tracking store, slice 2 (milestone 9) | #129 (#128): `mix ex_atlas.install --tracking-store ecto`, and the conformance suites in `lib` | 2026-10-02 |
| Database tracking store, slice 1 (milestone 9) | #123 (#120): `TrackingStore.Ecto`, its migration module and `ExAtlas.Orchestrator.Supervisor`, which the host starts after its repo | 2026-10-02 |
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
