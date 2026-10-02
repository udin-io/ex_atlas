# ExAtlas: notes for Claude sessions

ExAtlas is an Elixir library: one API over GPU clouds (RunPod first), plus an
opt-in orchestrator that tracks, polls and deletes pods. This file holds what
is true of this repo only, for the next session that works on it. The global
rules in `~/.claude/CLAUDE.md` still apply and are not repeated here. Added in
the follow-up to #67, because the repo had no root `CLAUDE.md`.

## Project source of truth

`docs/PROJECT.md` is the source of truth, with its pages: roadmap,
architecture, risks and decisions. #70 created them. Every PR that changes
behaviour, structure, a risk or a decision updates those pages in the same PR,
next to `README.md`, `guides/` and `CHANGELOG.md`. A merge is not finished
until they describe `main` as it is.

## Commands

```sh
bin/ci                     # every CI step; run before each push
RUNPOD_API_KEY=... mix test --only runpod_live   # rents a real RunPod pod
bin/audit                  # the weekly mix_audit run, not part of bin/ci
```

- `bin/ci` is the one place CI's steps live: format, forced compile with
  warnings as errors, credo, `hex.audit`, sobelow, a sobelow gate on
  `lib/ex_atlas/callback*`, then `mix test`. `.github/workflows/ci.yml` only
  calls it.
- `test/test_helper.exs` excludes `:runpod_live`. Those tests spend real
  money, so only the owner runs them, with their own key. A plain `mix test`
  and CI never run them.
- The repo has no database, so a worktree needs no partition DBs.

## Project-specific lessons

### CI is red at `hex.audit` on cowlib, and that is accepted

On Actions, `hex.audit` (Hex 2.5) reports OSV advisories as well as retired
packages. It fails on cowlib 2.20.0, the newest release, for
EEF-CVE-2026-43966 (medium) and EEF-CVE-2026-43969 (low). Neither lists a
fixed release. Cowlib comes in only through the test-only `bypass`. The
owner's decision on #53 (decision 4) keeps the step and suppresses nothing,
so `ci` stays red until cowlib ships a fix.

- **Symptom:** every PR's `ci` check fails at `hex.audit`, and CI never runs
  sobelow or `mix test`. The local `bin/ci` is then the only full run: report
  its test count and exit code, and say CI never reached the later steps.
- **Local runs differ:** Hex 2.4 prints retirements only (#55), so local
  `hex.audit` passes. A local pass does not cover that step.
- Never add `--ignore-advisory-ids`, an ignore file or a skip to make it
  green.

### Optional provider callbacks go through `dispatch_optional/3`

`ExAtlas.Provider` lists its newer callbacks in `@optional_callbacks`:
endpoints, `compute_spend`, templates and network volumes. `ExAtlas` calls
them through `dispatch_optional/3` in `lib/ex_atlas.ex`. It returns
`{:error, %ExAtlas.Error{kind: :unsupported}}` when the provider module does
not export the function.

- A new optional callback adds its name to `@optional_callbacks` and its
  public function calls `dispatch_optional/3`, never the module directly.
  The Fly, Vast and Lambda Labs stubs define none of them, and the Mock
  defines only `compute_spend/3`, so a direct call raises
  `UndefinedFunctionError` there.
- Test the `:unsupported` path with a provider that lacks the callback.

### The Mock's price drives every cost test

`ExAtlas.Providers.Mock` spawns at `provider_opts: %{cost_per_hour: rate}`
(default `0.0`; `nil` spawns a compute that reports no price).
`Mock.set_cost_per_hour/2` changes a stored compute's price, so the next
status poll sees it.

- Tests use `cost_per_hour: 3600.0`, which is $1 per second, so a `max_cost`
  of a few cents fires in tens of milliseconds.
- To prove a path that a later status poll would also cover, arm
  `ExAtlas.Test.FaultyProvider` with `{:block, self()}` on `:get_compute`.
  It holds every later poll open. #67's respawn re-pricing test does this.
- `Mock.set_spend/2` sets a pod's bill, and `Mock.spend_requests/1` lists the
  window of each billing read. `FaultyProvider` faults `:compute_spend` like
  any other call; `{:notify, self(), fault}` counts calls. A provider with no
  `compute_spend/3` at all is `NoBillingProvider` in
  `compute_server_test.exs` (#66).
