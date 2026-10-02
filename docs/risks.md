# Risks

This page lists the risks found in ExAtlas's code comments, guides and
`CLAUDE.md`, each with what we watch and what we would do. PR #70 creates it.
It feeds the choice of the next ticket: a risk with no mitigation is a
candidate. Kinds: technical (T), operational (O), product (P).

| # | Kind | Risk | What we watch | What we would do |
|---|---|---|---|---|
| 1 | T | RunPod does not document how far its billing API lags. `compute_spend/2` is not a live cost, so a low bill may only be late | `{:spend_reconciled, ...}` events: `billed_usd` far below `estimated_usd` after hours | The estimate fires the cap; the bill only raises spend. Measure the lag against a live pod, then document it |
| 2 | O | CI is red at `hex.audit` on cowlib 2.20.0 (EEF-CVE-2026-43966, EEF-CVE-2026-43969), no fixed release. Cowlib comes in only through test-only `bypass`. Sobelow and `mix test` never run on Actions | A cowlib release past 2.20.0 | Upgrade, then the step passes. Until then run `bin/ci` locally and report its test count. Never add an ignore (decision 4 on #53) |
| 3 | O | The default DETS tracking store lives on the machine's own filesystem. On Fly without a volume it comes up empty every deploy; adoption does nothing and the Reaper deletes the pods | Hosts using `persist: true` without `:storage_path` on a mounted volume | Mount a volume, or implement `TrackingStore` on a database |
| 4 | O | The Reaper reaps nothing for the whole boot when the store cannot be read (`:adoption_failed`), or when the node has no `reap_owner` and sees peers, or when another node reports the same owner | Error logs from `Reaper` | Fix the store or set a unique `reap_owner`. A leak is bounded by `max_runtime_ms` |
| 5 | O | A node with no owner and no peers reaps every untracked pod with the prefix, including pods of machines that share the account without clustering | Deployments with several machines on one account | Set `reap_owner` per machine |
| 6 | O | Pods of a node that is gone, pods named before the owner was set, and other nodes' pods are only logged once per boot | Reaper logs | The operator deletes them by hand |
| 7 | T | A RunPod pod keeps running and billing after its container exits. Only self-termination or `max_runtime_ms` ends it | Task sessions that outlive their command | `run_task/1` defaults both on; keep `self_terminate` unless you accept the backstop only |
| 8 | T | Without a finish report, `{:task, :completed}` means the container ended, not that it succeeded | Tasks that report no exit code | Use `ExAtlas.Callback` so the exit code is proven |
| 9 | T | Preemption is inferred, not reported: a `spot: true` pod that disappears is called `:preempted` | Respawn loops | Accept it; RunPod no longer sells spot pods and `spot: true` returns `:unsupported` there |
| 10 | T | Cost estimate leaves seconds uncounted: the provider call before the tracker starts, and the overlap between a replacement's spawn and the old pod's DELETE | Spend against bill | Seconds against a cap in dollars; accepted in #28 |
| 11 | T | An `EXITED` RunPod pod reads `cost: 0.0` while its disk still bills | Exited pods the tracker did not delete | `UpstreamStatus` ends the session on `EXITED`, so the estimate stops with it; the disk bill is outside the cap |
| 12 | T | Rolling back to a build before #69 leaves records written since the upgrade unadopted (older builds skip version 3 records) | Rollbacks while `persist: true` tasks run | `stop_tracked/1` those tasks first, or delete pods and records by hand |
| 13 | T | A host store that maps record fields to columns needs the four cost columns, or an adopted task's budget starts fresh | Host `TrackingStore` implementations | Add `:max_cost`, `:spent_usd`, `:cost_rate`, `:cost_since_ms` |
| 14 | O | Live RunPod tests (`--only runpod_live`) spend real money and are excluded from `mix test` and CI | Nobody runs them | Owner runs them with their own key |
| 15 | T | Local `hex.audit` (Hex 2.4) prints retirements only, so a local pass does not cover the CI step | Hex version | Compare Hex versions before trusting a local pass |
| 16 | T | After a respawn and then a node restart, the bill for the current pod is compared with the whole session's stored spend, since the record does not say which pod spent it. A bill can then raise the spend by less than it should (cap $10: $4 on pod A, $1 estimated on pod B billed $5.50 raises spend to $5.50, not $9.50) | Respawned tasks that are adopted with `persist: true` and `max_cost` | Store the current pod's starting spend in a version 4 record, with a new column in host stores |
| 17 | T | `s3:` credentials sit in a third-party GPU pod's environment, readable by anyone with access to that pod | Callers passing long-lived, bucket-wide keys | Scope keys to the two prefixes with a session token; presigned-URL mode lands in #73 |
| 18 | T | We assume RunPod's `POST /v2/pods` response echoes `env` as `GET` does. `Spec.Compute` hides `raw` from `inspect/1` either way, but `compute.raw["env"]` holds the credentials for code that reads it | Code that logs `compute.raw` | Read `raw` only for fields ExAtlas does not normalize; never log it |
| 19 | T | Whether RunPod v2 merges a body's `env` into a template's or replaces it is unknown; with `template_id`, the staging variables may replace the template's env | Pods spawned with `template_id` and `s3:` | A live probe with a template that sets env |
