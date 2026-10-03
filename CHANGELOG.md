# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and ExAtlas adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed: a DETS store down or recreated no longer lets the Reaper delete a recorded pod (#154)

- `TrackingStore.Dets.get/1` raises `ArgumentError` while its table is not
  open (the store process is down or restarting, or its file would not
  open), where it answered `:error`. `:error` means "not stored", and a
  Reaper tick in that window deleted a pod that had a record. Every caller
  rescues the raise: the Reaper keeps the pod, and a tracker keeps its pod on
  a supervisor stop.
- A DETS store that recreated a corrupt file, or could not open it, answers
  `{:error, _}` from `all/0` until the VM restarts. A restart of its process
  answered `{:ok, records}` with the lost records missing. While marked, its
  `get/1` raises on a miss, so a Reaper whose adoption settled before the
  loss keeps the pod.
- A DETS file deleted after the VM opened it, and a file garbled under the
  open table, answer `{:error, _}` from `all/0`, where they answered
  `{:ok, []}`.
- The DETS store closes its table before its process exits on a shutdown,
  and ignores a stray message instead of crashing.
- A tracker whose tracking store call exits (a store process that died
  mid-call) carries on and keeps its pod, as it does on a raise. It crashed,
  and the crash deleted the pod.
- A custom `TrackingStore` raises from `get/1` when it cannot answer; the
  callback doc now says so.

## v0.10.0 — 2026-10-03

### Upgrading

A live node now deletes a dead owner's pods, and the Ecto store signs owner
lease rows. Read [the upgrading guide](guides/upgrading.md), or run
`mix igniter.upgrade ex_atlas` to see whether your config sets the Ecto
store.

- On `TrackingStore.Ecto`, add a migration calling
  `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 3)` (and
  `down(version: 3)`). It adds the `mac` column. Until it runs, no owner reads
  as dead and each boot logs one warning (#148).
- Dead-owner deletion is on by default once step 3 ran (#144, #145, #148).
  Set `config :ex_atlas, :orchestrator, reap_dead_owners: false` to turn it
  off. Give every node the same `lease_ttl_ms`, cluster the nodes, and let
  only the app write `atlas_owner_leases`.
- Accepted risk: a writer of `atlas_owner_leases` can replay an old signed
  row of a live unclustered node, or hold a row lock that blocks its
  renewals, for the whole `:reap_dead_owner_after_ms` window. That node's
  untracked pods go. Clustering closes it; `reap_dead_owners: false` turns
  deletion off.
- A custom `TrackingStore` answers `expired_leases/1` with
  `%{owner => {expires_at_ms, mac}}`, stores `TrackingStore.lease_mac/2` in
  `renew_lease/2`, and implements `delete_expired/3` to let a dead owner's
  record release its pod (#144, #145, #148).

### Added: a dead owner's record no longer keeps its pod billing (#145)

A record a dead owner still held kept the Reaper off its pod, even when no
node would ever take it over: an unsigned record, or one this build would
not adopt. Now, once that owner reads as dead and the pod's name carries
it, the Reaper deletes the record, then the pod:

    [warning] [ExAtlas.Orchestrator.Reaper] deleted pod-4 (atlas-m1-train-2)
    and its tracking record: owner "m1" has not renewed its lease since
    2026-10-02T21:00:00Z, and no connected node reports it

A record the Lease would take over stays the Lease's. The record goes
through the new optional `TrackingStore.delete_expired/3`, which deletes it
only while its row still names that owner and the owner's lease still has
the expiry read as dead, so a record another node just claimed keeps its
pod. `TrackingStore.Ecto` implements it; a custom store without it keeps
every record's pod, as before. `reap_dead_owners: false` turns this off
with the rest of dead-owner deletion.

### Changed: owner lease rows are signed, and dead-owner deletion is on by default (#148)

Each `TrackingStore.Ecto` lease renewal writes an HMAC of the owner and
expiry, under a key from `config :ex_atlas, :callback, secret:` with its own
salt. The Lease reads an owner as dead only from a row its key verifies, so
one `INSERT` into `atlas_owner_leases` by a writer without the secret no
longer deletes a live node's pods. With that in place, the Reaper deletes a
dead owner's untracked pods unless `reap_dead_owners: false` is set.

A custom store's `expired_leases/1` now answers
`%{owner => {expires_at_ms, mac}}`, and its `renew_lease/2` stores
`TrackingStore.lease_mac/2` beside the expiry.

- **Upgrade:** add a migration calling
  `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 3)`. Until
  it runs, rows are unsigned, no owner reads as dead, and each boot logs one
  warning. Set `reap_dead_owners: false` to keep the deletion off. See
  [the upgrading guide](guides/upgrading.md).

### Added: a live node deletes a dead owner's untracked pods (#144)

A machine destroyed while it ran `spawn/1` sessions left their pods billing
with no tracker, and every other node only logged them. With
`TrackingStore.Ecto`, `:reap_owner` and a callback secret, the Reaper now deletes an untracked pod named with another owner once that owner's lease has
stayed expired, unchanged, for `:reap_dead_owner_after_ms` (15 minutes by
default, from two `lease_ttl_ms` to 24 hours):

    [warning] [ExAtlas.Orchestrator.Reaper] deleted pod-9 (atlas-m1-notebook-3):
    owner "m1" has not renewed its lease since 2026-10-02T21:00:00Z, and no
    connected node reports it

It keeps the pod when a connected node reports that owner, when any
connected node reports no valid owner or cannot report one, and when this
node has not renewed its own lease for the whole window. A node that just
booted waits a full window. A store of your own opts in with the optional
`expired_leases/1` callback.

A delete that raises or exits no longer stops the Reaper's tick: it logs the
error's kind and the next pod goes on.

- **Upgrade:** on by default since #148 signs lease rows (above). An
  unclustered live node still loses its untracked pods when it is cut off
  from the database for the whole window, or when it renewed signed rows and
  then stopped renewing. Give every node the same `lease_ttl_ms`, cluster
  the nodes, and let only the app write the table.

## v0.9.0 — 2026-10-02

### Upgrading

Five changes decide which persisted tasks a node adopts after a restart, and
what a custom tracking store must keep. Read
[the upgrading guide](guides/upgrading.md), or run `mix igniter.upgrade ex_atlas`
to see whether your config sets a callback secret.

- Set `config :ex_atlas, :callback, secret:`. Without it a record is
  unsigned: an adopted task cannot respawn (#131), and adopts only a pod this
  node's Reaper would delete (#138).
- Move per-call `base_url:` and `req_options:` of `persist: true` spawns to
  `config :ex_atlas, <provider>`; a custom provider module declares
  `@behaviour ExAtlas.Provider` (#125).
- A custom `TrackingStore` returns each record term for term: `:mac`,
  `:respawning` and the callback's `:attempt` (#131, #114, #110).
- `TrackingStore.Ecto` is new. A database that ran its step 1 from `main`
  before this release needs a migration calling `Migration.up(version: 2)`
  (#132).

### Added: `mix ex_atlas.upgrade` 0.9.0 step (#141)

The step edits no file. It adds a notice when your app starts the
orchestrator and no config file sets `config :ex_atlas, :callback, secret:`,
and links the upgrading guide. The reap-owner notice now finds a
`:reap_owner` set inside an `if` block in `runtime.exs`, as the
start-orchestrator check already did.

### Added: a live node takes over a dead node's tasks on the Ecto store (#132)

A machine destroyed while its tasks ran left them untracked: no deadline, no
cost cap, no respawn. With `TrackingStore.Ecto` and `:reap_owner` set, each
node now renews an owner lease, and a live node adopts the signed records of
an owner whose lease expired.

```elixir
# m1 is destroyed while pod-abc runs
# before: m2 logs "leaving 1 record(s) of owner \"m1\"" and never tracks it
# after, within lease_ttl_ms (90 s by default), on m2:
ExAtlas.Orchestrator.list_ids()
# => ["pod-abc"]
```

- `ExAtlas.Orchestrator.Lease` renews every `lease_ttl_ms / 3` (1 s to one
  hour) and claims each record with one conditional `UPDATE`, so two live
  nodes never both adopt it. A node that cannot renew claims nothing, and a
  node claims only after it held its own lease one full ttl.
- Only records this node's key verifies are taken over. An unsigned record
  of a dead owner is logged once and left. A node with no callback secret
  runs no lease.
- A node stops its trackers of records another node took over, and leaves
  their pods running.
- `TrackingStore` gains two optional callbacks, `renew_lease/2` and
  `claim_expired/3`. DETS and custom stores keep the old behaviour.
- **Upgrade:** `Migration` step 2 creates `atlas_owner_leases`. A database
  that ran step 1 needs a migration calling `Migration.up(version: 2)`.

### Fixed: a forged tracking record no longer deletes another app's pod (#138)

A writer of the tracking store without the callback secret could file an
unsigned record under any pod id of the account, with its deadline spent.
The next boot adopted it, and the deadline deleted that pod with the node's
key.

```elixir
# a row in atlas_tracking_records, no :mac, id: "pod-of-other-app"
# the provider names that pod "billing-db"
# before: adopted, then ExAtlas.terminate("pod-of-other-app")
# after:  [warning] not adopting pod-of-other-app: its record is not signed by
#         this node, and the provider names the pod "billing-db", which this
#         node's Reaper would not delete ...
```

- An unsigned record adopts only for a pod the Reaper deletes once
  untracked: its provider is in `:reap_providers`, the provider reports it
  `:provisioning` or `:running`, the node has a `:reap_owner` or no connected
  peers, and the name starts with `:reap_name_prefix` and carries the owner.
  Any other one is kept, logged and not claimed. So is one whose provider
  does not answer at boot; the next boot checks it again. Signed records
  adopt as before.
- **Upgrade:** a task persisted by 0.8.0, by a node with no callback secret,
  or under a rotated secret, is no longer adopted after a restart when its
  pod fails that test: for example a `:mock`, `:vast` or `:lambda_labs` task
  under the default `reap_providers: [:runpod]`, or a name without the prefix
  or this node's owner. The Reaper leaves such a pod
  alone too: terminate it by hand. A `persist: true` spawn on a node with no
  callback secret warns when its task will not pass.
- A RunPod pod id goes into the URL as one encoded path segment, as Vast and
  Lambda ids already did: an id from a store writer adds no path.

### Fixed: an adopted task respawns only from a record this node signed (#131)

A tracking record's writer chose what an adopted task's respawn rented: the
image, command, GPU, env names and the callback descriptor the node minted a
token over. With `respawn_credentials:`, the host's resolver sent its secrets
into that image.

```elixir
# a row edited in atlas_tracking_records: opts[:image] => "attacker/miner"
# the adopted pod is preempted
# before: rents attacker/miner, calls the resolver, mints a callback token
# after:  {:respawn_failed, {:preempted, %ExAtlas.Error{kind: :validation,
#           message: "cannot respawn: the tracking record is not signed by this node ..."}}}
```

- The node signs every record it writes, under `:mac`, with a key derived
  from `config :ex_atlas, :callback, secret:`. Any edit of any field breaks
  the signature. A rewrite re-signs only a record whose signature checked.
- **Upgrade:** a task persisted by 0.8.0, or by a node with no callback
  secret, still adopts and keeps its deadline and cost cap, but cannot
  respawn after a restart. Neither can a task signed under a callback secret
  you then rotate. A respawnable `persist: true` spawn on a node with no callback
  secret logs a warning.
- A custom tracking store must return each record term for term, `:mac`
  byte for byte. The conformance suite checks it.

### Added: `mix ex_atlas.install --tracking-store ecto` (#128)

The installer sets up `ExAtlas.Orchestrator.TrackingStore.Ecto` in one run:
the migration, the config, and `ExAtlas.Orchestrator.Supervisor` right after
the repo in your application's children. A second run changes nothing.

```sh
mix ex_atlas.install --tracking-store ecto     # --repo MyApp.Repo with several repos
mix ecto.migrate
```

```elixir
# lib/my_app/application.ex
# before: children = [MyApp.Repo, MyAppWeb.Endpoint]
# after:  children = [MyApp.Repo, ExAtlas.Orchestrator.Supervisor, MyAppWeb.Endpoint]
```

- `config/config.exs` gets `start_orchestrator: false` and the orchestrator's
  `tracking_store:` and `repo:`. A `start_orchestrator: true` there becomes
  `false`. One the installer leaves, in another config file or inside an
  `if config_env() == :prod` block, gets a warning naming the file; so does
  another `tracking_store:`.
- Replacing another tracking store adds a notice: its records are not moved.
- The migration goes in the repo's migrations directory, its literal `priv:`
  included. One that already calls
  `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration` stops a second one.
- No repo, several repos and no `--repo`, a repo missing from the
  application's `children` list, or a store other than `ecto` stop the task
  before it writes anything. `--repo` also takes a repo built on your own
  wrapper module.

### Fixed: the conformance suites ship in the package (#128)

The guides told hosts to `use ExAtlas.Orchestrator.TrackingStoreConformance`
and `ExAtlas.Test.ProviderConformance`, but both lived in `test/support` and
were not in the hex package.

```elixir
use ExAtlas.Orchestrator.TrackingStoreConformance, store: MyApp.AtlasStore
# before: ** (CompileError) module ExAtlas.Orchestrator.TrackingStoreConformance is not loaded
# after:  the shared contract tests run against MyApp.AtlasStore
```

Both call ExUnit only inside the tests they expand in your test module, so
they compile in a prod build.

### Fixed: the reap-owner notice covers a host-started orchestrator (#128)

`mix ex_atlas.upgrade`'s 0.8.0 step told a host with no `:reap_owner` to set
one only when the config set `start_orchestrator: true`. It now also fires
when a module names `ExAtlas.Orchestrator.Supervisor`, and the installer shows
the same notice.

### Fixed: `Error.raw` keeps no `env` at any depth (#136)

An error body that wraps the resource it refuses, or that arrives atom-keyed
(`req_options: [decode_json: [keys: :atoms]]`), still carried `env` after #133.

```elixir
# RunPod answers 409 {"detail": "in use", "conflict": {"id": "ep1", "env": {"HF_TOKEN": "..."}}}
{:error, e} = ExAtlas.get_endpoint("ep1", provider: :runpod)
e.raw   # before: the whole body   after: %{"detail" => "in use", "conflict" => %{"id" => "ep1"}}
```

- Every key named `env` (string or atom) goes, at any depth, on any provider
  that shares `HTTP.handle_response/3`. The rest of the body stays; a field
  named `environment` stays. An atom-keyed `errors[].value` goes too, as the
  string-keyed one already did. Only the key `env` is scrubbed: a body that
  echoes Vast's `extra_env` or Lambda's `jupyter_token` keeps them.
- An atom-keyed error body now gives `Error.message` its `detail`, `message`
  or `errors[]` text, as a string-keyed one does; it read `nil` before.
  `errors[].value` stays out of the text either way.
- `errors[].value` goes from an `errors` list at any depth, under a string or
  an atom key, not only from the top-level list.
- A Req exception that can hold the response body (`Req.DecompressError`,
  `Req.HTTPError`, a caller decoder's error) now reaches `ExAtlas.Error` as its
  module name only, with `raw: nil`. Before, `raw` kept the exception, and a
  bad gzip body echoing the request printed in full. A transport error
  (`Req.TransportError`, `Mint.TransportError`, `Finch.Error`) and a redirect
  loop keep their message and `raw`. A `JSON.DecodeError` is withheld as a
  `Jason.DecodeError` already was.
- A plain-text error body that echoes the request stays in `Error.message`:
  nothing can tell the secret from the text.

### Fixed: `Endpoint.raw` and `Template.raw` no longer hold RunPod's `env` (#133)

RunPod echoes an endpoint's or template's `env` (a Hugging Face token, a
W&B key) in its body. `inspect/1` hides `raw`, but a crash report of a process
that holds the struct, or `inspect(.., structs: false)`, printed the values.

```elixir
{:ok, ep} = ExAtlas.get_endpoint("4m7x2k9q", provider: :runpod)
ep.raw["env"]                 # before: %{"HF_TOKEN" => "..."}   after: nil
ep.raw["template"]["env"]     # before: %{"HF_TOKEN" => "..."}   after: nil
# the same for each pod in ep.raw["workers"] when RunPod lists them
```

- `get_endpoint/2`, `list_endpoints/1`, `get_template/2`, `list_templates/1`
  and `create_template/1` apply it. Every other `raw` key stays.
- `Spec.Template.env` still holds the template's configured values: it is a
  normalized field, and `inspect(template, structs: false)` prints it.
  Read values you need from `env`, not `raw["env"]`.
- An error for a 3xx, 4xx or 5xx status whose body echoes a resource keeps no
  `env` in `Error.raw`, on every provider that shares `HTTP.handle_response/3`.
  The rest of the body stays. Only the `env` key goes.

### Fixed: a forged tracking record no longer steers an adopted task's calls (#125)

Whoever could write the tracking store (the DETS file, or a row in your
database with `TrackingStore.Ecto`) chose where an adopted task sent its
provider calls, with the API key from your config.

```elixir
# a row in atlas_tracking_records
%{id: "pod-1", provider: :runpod, opts: [base_url: "https://attacker.example"], ...}

# next boot, the adopted task's status poll
# before: GET https://attacker.example/pods/pod-1, Bearer <RUNPOD_API_KEY>
# after:  GET <config :ex_atlas, :runpod, base_url:, else RunPod's URL>/pods/pod-1
```

- A record no longer stores `base_url:` or `req_options:`. An adopted task
  takes both from config, and ignores an `api_key:` a record holds, as it
  always took the key from config. The first rewrite of a record drops all
  three. The Adopter logs the keys of a record that held them, never the
  values.
- The Adopter adopts a record only when its provider is built in or a module
  that declares `@behaviour ExAtlas.Provider`. Any other record is skipped,
  kept, and logged, so the Reaper still leaves its pod alone.
- **Upgrade:** if you pass `base_url:` or `req_options:` per call to a
  `persist: true` spawn, set them in `config :ex_atlas, <provider>` before you
  deploy. Otherwise a task adopted after the deploy calls the provider's
  public URL. A fresh spawn still uses its per-call values. A custom provider
  module adds `@behaviour ExAtlas.Provider` to keep its tasks adopted.

### Added: `base_url:` and `req_options:` in every provider's config (#125)

`ExAtlas.Config.build_ctx/2` reads `config :ex_atlas, <provider>, base_url:,
req_options:` for a call that passes none, as it reads `api_key:`. Per-call
`req_options` merge over the configured ones key by key, and a credential in
either is sealed. RunPod gains a configured `base_url:` (the management API,
as a per-call one); Lambda Labs and Vast read theirs as before.

### Fixed: `Compute.raw` no longer holds a RunPod pod's `env` (#126)

RunPod echoes a pod's `env` (its bearer token, the callback token and the
`s3:` secret) in the pod body. A tracker holds the `Compute` in its state and
poll replies, so a crash report's last message or `inspect(.., structs: false)`
printed them.

```elixir
{:ok, compute} = ExAtlas.get_compute(id, provider: :runpod)
compute.raw["env"]
# before: %{"HF_TOKEN" => "...", "ATLAS_CALLBACK_TOKEN" => "..."}
# after:  nil
```

- Every other `raw` key stays. Code that read `compute.raw["env"]` gets `nil`:
  read the value you passed to `spawn_compute/1` instead.
- An error for a success status the caller did not expect (a spawn answered
  `200` instead of `201`) keeps no `raw`, and `get_compute/2` keeps none for a
  200 body that is not a pod object: either body can hold pods and their `env`.
- `Spec.Endpoint.raw` and `Spec.Template.raw` follow in the next entry (#133).

### Added: keep tracking records in your database (#120)

`ExAtlas.Orchestrator.TrackingStore.Ecto` stores `persist: true` records in a
table of the host's Ecto repo, so a task survives a deploy on a machine with no
volume. `ExAtlas.Orchestrator.Supervisor` starts the orchestrator in the host's
tree, after the repo.

```elixir
config :ex_atlas, start_orchestrator: false
config :ex_atlas, :orchestrator,
  tracking_store: ExAtlas.Orchestrator.TrackingStore.Ecto, repo: MyApp.Repo

children = [MyApp.Repo, ExAtlas.Orchestrator.Supervisor, MyAppWeb.Endpoint]
# after a deploy on a machine with no volume
ExAtlas.Orchestrator.list_ids()
# => ["pod-abc"]   (before: [] and the Reaper deleted the pod)
```

- `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up/1` creates
  `atlas_tracking_records`; call it from a migration. `ecto_sql` is an
  optional dependency.
- A row that will not decode safely makes the boot adopt nothing and reap
  nothing, as an unreadable DETS file does.
- `ExAtlas.Orchestrator.Supervisor` refuses to start when
  `start_orchestrator: true` is also set.
- The orchestrator's functions now check that its tree is running, not the
  `start_orchestrator` flag. The "not started" error names both ways to start
  it.
- The store refuses a compressed row and a row over 1 MiB (1,048,576 bytes),
  since a compressed term declares its own decoded size, up to 4 GB. `put/1`
  logs a record over 1 MiB and writes nothing.
- The store writes in its own process, so a host that spawns inside a
  `Repo.transaction` and rolls back keeps the record of the running pod.
- The store refuses to start before its repo runs. `start_orchestrator: true`
  with the Ecto store fails at boot, since ExAtlas's tree starts before the
  host's repo.
- A tracker whose tracking store raises (a database that is down, a row that
  will not decode) logs it and runs on. Before, it crashed and deleted its pod.
- The callback limiter's "not running" error names both ways to start the
  orchestrator.

### Fixed: a Reaper that restarts reaps again (#122)

With a tracking store, a Reaper that crashed and restarted waited for the
Adopter's signal, which comes once per boot, and reaped nothing until the next
deploy. The Adopter now records its outcome before it signals, and a
restarted Reaper reads it.

```elixir
# adoption settled, then a tick raises
# before: the restarted Reaper logs "skipping this cycle until boot-time
#   adoption settles" on every tick, and orphans bill
# after:  the restarted Reaper reaps on its next tick
```

- A failed adoption stays failed: the restarted Reaper reaps nothing and logs
  that reaping is DISABLED for this boot.
- The record belongs to the supervisor the Reaper and Adopter share. A new
  tree, such as the app started again in the same VM, waits for its own
  Adopter.

### Fixed: a respawn the Reaper cannot clean up warns, and a revived pod reports (#118)

A spawn with `on_failure: {:respawn, n}` on a provider outside
`:reap_providers` logs a warning. A node that dies while a respawn rents leaves
the replacement running with no record, and only the Reaper deletes it.
`:vast` stays out of the default `reap_providers`: a Vast label is free text,
so the `atlas-` prefix can match an instance ExAtlas never rented.

```elixir
# reap_providers: [:runpod] (the default)
ExAtlas.Orchestrator.run_task(provider: :vast, spot: true, on_failure: {:respawn, 2}, ...)
# [warning] [ExAtlas.Orchestrator] "atlas-train" can respawn, and :vast is not
#   in :reap_providers. ... Add :vast to :reap_providers, or delete such a pod by hand.
```

- An adopted task whose node died mid-respawn accepts its record's pod's
  reports again once a poll reads that pod alive (an outbid spot instance
  that won its bid back). Before, it refused every token until its deadline.
  The orphan's token still gets 410, and the next respawn still uses the next
  attempt.
- A provider whose list raises or exits no longer crashes the Reaper's tick:
  the Reaper logs a warning with the error's kind and reaps the next
  provider. Before, RunPod with no API key, under the default
  `reap_providers`, crashed every tick, and the restarted Reaper stayed gated
  for the rest of the boot.
- A host-prepared `callback:` descriptor starts at attempt 0. A carried
  attempt was the one the first respawn issued again, so the replaced pod's
  report passed.
- `ExAtlas.Orchestrator.Reaper.covers?/1` says whether a provider is in
  `:reap_providers`, by atom or module.

### Added: Vast.ai `stop/2`, `start/2` and `compute_spend/3` (#116)

`stop/2` and `start/2` pause and resume a Vast instance, and `compute_spend/3`
reads its bill from Vast's charges API, so `max_cost` reconciles against real
spend on Vast:

```elixir
ExAtlas.stop(id, provider: :vast)          # => :ok, the instance reads :stopped
ExAtlas.start(id, provider: :vast)         # => :ok
ExAtlas.compute_spend(id, provider: :vast)
# => {:ok, %ExAtlas.Spec.Spend{total_usd: 0.84, gpu_usd: 0.60, disk_usd: 0.20}}
```

- A stopped instance still bills its disk. `start/2` fails when the host
  rented the GPU to someone else; the error carries Vast's `error` code and
  never its `msg`.
- Vast bills by UTC day: `compute_spend/3` snaps `from` down to midnight and
  returns the snapped window. With no `:from` it starts at the instance's
  `start_date`.
- `capabilities(:vast)` now lists `:billing`.
- `Spend.raw` keeps an allow-list of row fields; a row's `description` and
  `metadata` stay out.

### Fixed: an orphan of a node that died mid-respawn gets 410 (#114)

A respawn writes `respawning: n` into the tracking record before it rents the
replacement. Before, a node that died between the rent and the record update
left the replacement running with no record and a token for attempt `n`. The
next boot adopted the preempted pod's record, respawned, and gave its own
replacement attempt `n` again, so the orphan's `finish` ended the task.

```elixir
# on_failure: {:respawn, 2}. Pod A preempted, node dies after renting B.
POST /atlas/cb/finish  Bearer <B's token, attempt 1>
# before: 202 once the next boot respawns, and the task ends on B's report
# after:  410; the next boot's replacement holds attempt 2
```

- The adopted task counts attempt `n` as spent. With `{:respawn, 1}` it rents
  nothing more and ends.
- Until its next respawn, it accepts no token: the record's pod was preempted.
  Since #118, a poll that reads that pod alive again lets its own token back.
- It logs a warning naming the pod name. The orphan bills until the Reaper
  deletes it; add the provider to `reap_providers` (`:vast` is not there by
  default), or delete it by hand.
- The record schema stays at version 3. A record without `:respawning`
  (0.8.0's) or with `nil` adopts as before. A host store that maps fields to
  columns needs a nullable integer `respawning` column; without one the
  orphan's token passes as before. Only a value past `respawns` counts, so a
  column default of 0 reads as no respawn.
- Rolling back: an earlier build ignores the field, and its respawn copies it
  onto the replacement's record. This build reads that stale value as no
  respawn, since it is not past `respawns`.
- A respawn refused before the rent (no `respawn_credentials:` resolver)
  records no attempt.

### Added: Vast.ai `spot: true` rents interruptible offers (#112)

`spot: true` on `provider: :vast` searches `type: "bid"` offers and rents the
cheapest, bidding exactly its `min_bid`. An outbid instance reads
`exited`, which the orchestrator already classes as `:preempted`, so
`on_failure: {:respawn, n}` rents a replacement and destroys the old instance:

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :vast, gpu: :rtx_4090, image: "pytorch/pytorch",
  command: ["python", "train.py"], spot: true,
  callback: "https://app.example.com/atlas/cb",
  on_failure: {:respawn, 3}, max_runtime_ms: :timer.hours(4)
)
# compute.cost_per_hour => the bid plus the disk, below the on-demand dph_total
```

- An offer with no positive numeric `min_bid` is skipped; Vast is never
  asked to rent an interruptible instance at `dph_total`. No such offer is
  `:provider`.
- `provider_opts: %{offer_id: id}` with `spot: true` is `:validation`: that
  rent searches nothing, so it has no `min_bid`.
- A bid search lists `dph_total` as the offer's `min_bid` plus the disk's
  storage, and sorts by it. The pick follows that order, and `cost_per_hour`
  is that `dph_total`.
- `capabilities/0` adds `:spot`. `list_gpu_types/1` fills
  `spot_price_per_hour` from a second, `type: "bid"` search per GPU: 26
  searches, not 13, four at a time. A failed bid search leaves
  `spot_price_per_hour` `nil` and keeps the on-demand prices. A GPU only the
  bid search lists has `lowest_price_per_hour: nil`.
- Pass a `callback:` to a spot task you respawn. A finished task deletes
  its instance, which reads like an outbid one; the finish report tells the
  tracker the task completed.
- A bid at `min_bid` loses to any higher bid. `provider_opts: %{bid_price: n}`
  is not in this release.

### Added: Vast.ai `command:`, `run_task/1` and the Reaper (#105)

`provider: :vast` takes `command:`. With the default `self_terminate: true`
the container deletes its own instance when the command ends, so
`ExAtlas.Orchestrator.run_task/1`, `max_cost` and the Reaper work on Vast:

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :vast, gpu: :rtx_4090, image: "pytorch/pytorch",
  command: ["python", "train.py"], max_runtime_ms: :timer.hours(2)
)
# => {:task, :completed} once train.py exits

config :ex_atlas, :orchestrator, reap_providers: [:runpod, :vast]
```

- The rent sends the command as Vast's `args`, which go to the image's
  entrypoint, wrapped in `sh -c` with the trap RunPod uses. It reports a
  `callback:`'s exit code first, then DELETEs
  `/api/v0/instances/$CONTAINER_ID/` with `$CONTAINER_API_KEY`.
- `self_terminate: false` sends the command unwrapped.
- `CONTAINER_ID` and `CONTAINER_API_KEY` in `env:`, and a `command:` argument
  with a NUL byte or not UTF-8, are `:validation`.
- `capabilities/0` adds `:self_terminate`.
- The image needs `sh`, `curl`, and an ENTRYPOINT, if any, that runs its
  arguments.

### Fixed: the self-terminating wrapper keeps keys off curl's argv (#105)

RunPod's and Vast's wrapper gave curl the pod key and the callback token as
`-H` arguments, which every process in the container reads in `ps`. Curl now
reads each header from a `-K -` config line on stdin, written by the
`printf` builtin. The wrapper sends nothing when the resource id, the key or
the callback token is not a plain token: a newline there would have set any
curl option.

### Added: Vast.ai compute provider, on-demand (#99)

`provider: :vast` spawns, reads, lists and terminates Vast.ai on-demand
instances, and `list_gpu_types/1` reads Vast's offers.

- A spawn searches Vast's on-demand offers (`POST /api/v0/bundles/`) for the
  GPU, count, disk (`container_disk_gb:`, default 20) and port count, and
  rents the cheapest (`PUT /api/v0/asks/{id}/`) in the first of
  `region_hints` (country codes) that has one. It runs `image:` with its own
  entrypoint, with `env:`, `s3:`, `auth:` and `ports:` in Vast's `env`
  object. `cloud_type: :secure` rents datacenter hosts only.
  `provider_opts: %{offer_id: id}` rents one offer with no search.
- A refused rent tries the next of the three cheapest offers. A rent that
  answers 5xx or times out is never retried: Vast may have rented.
- `get_compute/2` builds `http://ip:host_port` URLs from Vast's port map.
  `exited` reads `:stopped`; `offline` and `unknown` read `:failed`; a missing
  instance is `:not_found`. `list_compute/1` follows Vast's `next_token`.
- `raw` keeps only instance fields that hold no secret: Vast's body echoes
  the env (`extra_env`, `onstart`), the container's arguments and the Jupyter
  token. A refused rent keeps Vast's `error` code, when it is one, and
  withholds its `msg`, which can echo the request. The rent follows no
  redirect, which would resend the env to another host.
- An `env:` name that is not `[A-Za-z_][A-Za-z0-9_]*`, or a value that holds
  a NUL byte or is not UTF-8, is `:validation`: Vast reads other names as
  Docker flags.
- `template_id:`, `network_volume_id:`, `stop/2` and `start/2` return
  `:unsupported`.

### Fixed: a late report from a replaced pod no longer ends the replacement (#100)

Each pod's callback token now signs its attempt: 0 for the first pod, `n` for
the `n`th replacement. After a respawn, a `finish`, `progress` or `log` from
the preempted pod gets `410` and never reaches the replacement's tracker.
Before, the old pod's late `finish` ended the new pod's session and deleted
it mid-run.

`ExAtlas.Callback.ingest/3` takes the claims `verify/1` returned as its first
argument, and checks their attempt. A bare `task_id` still works and checks
nothing; move a hand-rolled controller to the claims form:

```elixir
:ok <- ExAtlas.Callback.ingest(claims, :progress, json)
```

A pod rented by 0.8.0 holds a token with no attempt; see #110 below.

### Fixed: a token with no attempt is refused once a respawn replaced the pod (#110)

A pod rented by 0.8.0 holds a callback token with no attempt claim. Before,
`ingest/3` accepted it unchecked, so after a respawn the replaced pod's late
`finish` still ended the replacement and deleted it. Now a token with no
attempt is accepted only while the tracker's current pod holds such a token
too: a task 0.8.0 stored, adopted after the upgrade and not respawned since,
or one 0.8.0 itself respawned. The first respawn this version makes gives the
replacement a token that signs its attempt, and from then on a claim-less
token gets `410`.

The respawn also writes the attempt into the stored record, so a restart
after it keeps refusing the replaced pod. A host `TrackingStore` must return
`opts[:callback]` with its `:attempt`; without it the adopted task reads as
0.8.0's and refuses the current pod's reports.

No setting changes: a running 0.8.0 pod reports as before until the task
respawns. A bare `task_id` passed to `ingest/3` still checks nothing.

One case stays open: a task that 0.8.0 respawned before the upgrade has two
claim-less pods, and nothing tells them apart, so the replaced one's late
report passes until the task ends.

### Fixed: a replaced pod's refused reports no longer spend its replacement's rate budget (#107)

The callback rate limit keys its bucket by task and attempt. Before, pod A
and its replacement pod B shared one bucket per task and kind, and the plug
spent it before it checked the attempt. Three late `/finish` posts from A
(each a `410`) emptied the burst of 3, and B's real exit code got `429` for up
to a minute.

`ExAtlas.Callback.take/2` takes the claims `verify/1` returned, as `ingest/3`
does. A bare `task_id` string still works and keys as a token with no
attempt, so a hand-rolled controller keeps compiling. Move it to the claims form:

```elixir
:ok <- ExAtlas.Callback.take(claims, :progress)
```

### Fixed: provider responses and the Vast GPU names (#99)

- `Spec.GpuCatalog`'s `:vast` names are Vast's spaced names, one list per
  family (`:h100` is `H100 SXM`, `H100 PCIE` and `H100 NVL`).
  `for_provider(gpu, :vast)` returns that list. The old underscore names
  (`RTX_4090`) matched no offer.
- A response body Req cannot decode as JSON no longer reaches the error's
  `raw`, on every provider: it can echo the request.
- A Lambda launch follows no redirect, which would resend `user_data`, env
  values included, to another host.

## v0.8.0 — 2026-10-02

### Upgrading

Six changes break host code or deployments. Read
[the upgrading guide](guides/upgrading.md), or run `mix igniter.upgrade ex_atlas`
to list the modules and config it affects.

### Added: Lambda Labs compute provider (#84)

`provider: :lambda_labs` spawns, reads, lists and terminates Lambda Cloud
on-demand instances, and `list_gpu_types/1` reads Lambda's catalog.

- A spawn with `image:` hands the instance a cloud-init `user_data` script
  that runs the image with `docker run --gpus all`, with `env:`, `s3:`,
  `auth:` and `ports:`. Values reach `docker` through its environment, never
  its argv. `env:`, `s3:`, `auth:` or `ports:` without `image:` is
  `:validation`; no image launches a plain VM.
- The spawn picks the first of `region_hints` with capacity, else Lambda's
  first region with capacity. `gpu_count: 8` launches `gpu_8x_<family>`.
  `provider_opts: %{instance_type: ..., ssh_key_name: ...}`; the SSH key
  falls back to `config :ex_atlas, :lambda_labs, ssh_key_name:`.
- Instance tags `atlas-ports`, `atlas-created-at` and `atlas-image` let
  `get_compute/2` and `list_compute/1` rebuild `ports`, URLs and
  `created_at` on any node.
- `stop/2`, `start/2`, `spot: true`, `template_id:` and
  `network_volume_id:` return `:unsupported`.
- `raw` leaves out `jupyter_token` and `jupyter_url`. A refused launch keeps
  its status and Lambda's error code, and withholds Lambda's message, which
  can echo `user_data`.
- An env name starting `DOCKER_` or `LD_`, a value or image that is not
  UTF-8, and an image starting with `-` are `:validation`.

### Added: Lambda Labs `command:` and `run_task/1` (#85)

- `command:` runs in the container, after the image, each argument
  shell-quoted. `command: []` runs the image's own command.
- With a `callback:`, the instance's host reports the container's exit code:
  a `systemd-run` unit runs `docker wait atlas` and POSTs
  `{"exit_code": n}` to `$ATLAS_CALLBACK_URL/finish`. `run_task/1` ends on
  that report and terminates the instance. The image needs no `curl`.
- `command:` with `self_terminate: true` (the default) and no callback is
  `:validation` before any request: Lambda gives an instance no key to
  delete itself, so nothing would end it.
- When the container never ran (`docker run` failed) or is gone, the host
  reports exit code 125, so the task ends at once instead of at
  `max_runtime_ms`. The unit deletes its script, which holds the token, as
  it starts.
- `command:` without `image:`, a command argument or image holding a NUL
  byte or not UTF-8, and an env name bash keeps for itself (`UID`,
  `RANDOM`, `BASH_*`, `COMP_*`, ...) are `:validation`. bash refused to
  export the readonly ones, which stopped the script before `docker run`.
- `config :ex_atlas, :lambda_labs, base_url:` sets the API URL for calls that
  pass none, such as the Reaper's list.
- An `atlas-created-at` tag more than ten minutes ahead of the clock reads
  as no `created_at`, so the Reaper gives that instance no grace window.

### Fixed: a callback URL with userinfo, a query or a fragment is refused (#85)

`ExAtlas.Callback.prepare/1` returns `{:error, {:invalid_callback_url,
:has_userinfo | :has_query | :has_fragment}}`, with or without
`allow_insecure_callback`. The pod appends `/finish`, which a query or a
fragment swallowed, so the report never arrived; userinfo showed in `ps`
wherever curl ran.

### Fixed: an interactive session ends on its command's finish report (#96)

`Orchestrator.spawn/1` with a non-empty `command:`, a `callback:` and
`self_terminate: true` (the default) now ends on the container's finish
report, as `run_task/1` does. `finish_grace_ms` (default 60 s) after
`{:task_report, report}`, the tracker broadcasts `{:terminating, :finished}`
and deletes the resource, unless it disappeared first (a RunPod pod deletes
itself). `touch/1` does not postpone it. Before, a Lambda
instance whose command had exited billed until the idle TTL.
`self_terminate: false` keeps the session up after the report, as before.

### Changed: interactive deadlines send `{:terminating, _}` (#96)

An interactive session past `max_runtime_ms` sends
`{:terminating, :max_runtime}`, and one still provisioning at
`ready_timeout_ms` sends `{:terminating, :never_ready}`. Both used to send
`{:task, :timed_out}` and `{:task, {:failed, :never_ready}}`, which `Events`
reserves for `mode: :task`. A host that matched `{:task, _}` on an
interactive session matches `{:terminating, _}` now; see
[the upgrading guide](guides/upgrading.md#terminating-messages). Task mode is
unchanged.

### Added: Lambda opens an instance's `ports:` in its firewall (#86)

A spawn with `ports:` creates one Lambda firewall ruleset for the instance
and launches the instance with it attached.

- The ruleset is `atlas-<instance name>-<8 hex>` and holds one TCP rule per
  distinct port, from `provider_opts: %{source_network: cidr}` or
  `0.0.0.0/0`. A `source_network` that is not a string is `:validation`.
  `ports: []` creates no ruleset, and neither does `us-south-1`, where Lambda
  applies no firewall rules.
- A refused ruleset create fails the spawn before the launch. A launch
  Lambda refuses with a 4xx deletes the ruleset it created; after a 5xx or a
  timeout the ruleset stays, since the instance may hold it.
- `terminate/2` deletes the instance, then its ruleset. Lambda refuses while
  the instance still uses the ruleset (`firewall-rulesets/firewall-ruleset-in-use`);
  `terminate/2` still returns `:ok`. Every spawn with `ports:` first deletes
  rulesets named `atlas-...-<8 hex>` that no instance uses and that are 5
  minutes old or more, at most 10 a spawn. A ruleset you name `atlas-prod` is
  yours.
- `terminate/2` makes one more call, `GET /firewall-rulesets`, to find the
  instance's ruleset.

### Changed: spawn POSTs retry on a 429 only (#84)

`RunPod.Pods.create/2` never retried; it now retries a 429, which means
RunPod made nothing. A 5xx or a timeout is still returned at once, since the
pod may exist. Lambda's launch follows the same rule
(`ExAtlas.Providers.HTTP.retry_rate_limited/2`).

### Fixed: Lambda instance type names in `Spec.GpuCatalog` (#84)

`:rtx_6000` is `gpu_1x_rtx6000` and `:a100_80g` is `gpu_1x_a100_80gb_sxm4`,
as Lambda names them. `:gh200` maps to `gpu_1x_gh200`.

### Added: `respawn_credentials:`, a respawn after a deploy (#87)

A `persist: true` task with `s3:` or `env:` that was preempted after a
restart ended with `{:respawn_failed, ...}`, since its record holds no
secret. Now:

- `Orchestrator.spawn/1` and `run_task/1` take `respawn_credentials: {m, f,
  args}`. It needs `persist: true`, a module that declares `@behaviour
  ExAtlas.Orchestrator.RespawnCredentials`, a function exported with arity
  `length(args) + 1`, and args with no closure or `ExAtlas.Secret`;
  otherwise the spawn is a
  `NimbleOptions.ValidationError` on `:respawn_credentials`, before any rent.
- The record keeps the tuple. `config :ex_atlas, :orchestrator,
  respawn_credentials:` serves records without one.
- An adopted task's respawn calls `apply(m, f, args ++ [info])`, where
  `info` is `%{id:, name:, user_id:, provider:, s3:, env_names:}`, and
  rents the replacement with the `s3:` and `env:` it returns. The record
  keeps its markers. A task that never restarted does not call it.
- A missing, failing, raising or slow resolver (bound:
  `respawn_credentials_timeout_ms`, default 30,000) ends the task as before,
  with a message that names the resolver and no value.
- An adopted record whose tuple no longer validates adopts without it and
  logs a warning.
- `Spec.Staging.new/1` refuses a value that is not valid UTF-8, naming the
  key. It raised before, with the value in the stacktrace.

### Changed: `env:` values print redacted and stay off disk (#79)

A tracker crash printed every `env:` value, and a `persist: true` record
wrote them to disk. Now:

- `Orchestrator.spawn/1`, `run_task/1`, a directly started tracker and
  `ComputeRequest.new/1` hold each `env:` value as an `ExAtlas.Secret`.
  `ComputeRequest.container_env/1` returns the values for the provider body.
  An `env:` that is not a map is refused by name with `value: nil`.
- No provider ctx carries `env:`; it belongs to the request alone.
- A tracking record keeps the names: `%{"HF_TOKEN" => :not_stored}`. With
  `scrub_keys: [:env]` it keeps `env: :not_stored`, where it used to drop
  `env:` and let an adopted respawn run with no environment. An empty `env:`
  is stored as `%{}`.
- An adopted task whose record left out values refuses a respawn with
  `{:respawn_failed, {reason, %ExAtlas.Error{kind: :validation}}}`, naming
  the variables, and rents no pod. A respawn before any restart still sends
  every value. A record written by an earlier build keeps its values for one
  adoption: the adopted tracker seals them and its respawn sends them, and
  every rewrite of the record stores names only. The string `"not_stored"`,
  as a store that keeps atoms as strings returns it, refuses the respawn too.
- `Spec.TemplateRequest` holds its `env:` values as Secrets too
  (`TemplateRequest.env/1` returns them), and an invalid template `env:` is an
  error with `value: nil`.
- `provider_opts: %{"env" => ...}` still reaches the RunPod body and the
  record as given. Put secrets in `env:`.

The record schema stays at version 3. Rolling back: an earlier build reads
`:not_stored` values, and that task's respawn fails `ComputeRequest`
validation and deletes the pod.

### Added: `persist: true` with `s3:` (#74, slice 4 of #26)

`persist: true` with `s3:` is no longer refused. The tracking record keeps
`s3:`'s `endpoint`, `region`, `dataset_uri` and `artifact_uri`, plus
`credentials: :not_stored`; never the keys, the session token or the
presigned URLs. An adopted task runs on. A respawn after adoption has no
credentials, so it broadcasts `{:respawn_failed, {reason,
%ExAtlas.Error{kind: :validation}}}` and ends the task without renting a pod.
A respawn before any restart still carries the full `s3:`.
`Spec.Staging.new/1` refuses `credentials: :not_stored`. The record schema
stays at version 3. Rolling back: a build from #75 to #80 crashes that
respawn and deletes the pod; a build before #75 respawns with no staging.

### Added: presigned-URL mode for `s3:` (#73, slice 3 of #26)

`s3:` takes `dataset_url` and `artifact_url`, two URLs you presign on your
side. They become `ATLAS_DATASET_URL` and `ATLAS_ARTIFACT_URL`, and the pod
gets no storage key. Each must be `http://` or `https://` with a host and no
user info. `Spec.Staging` holds them as `ExAtlas.Secret`s, so `inspect/1`,
validation errors and crash reports never print them. `s3:` now needs one of
`dataset_uri`, `artifact_uri`, `dataset_url` or `artifact_url`; the error for
none says so. A URL also needs a path to an object and only RFC 3986
characters after the host, with no braces or brackets. The reference
entrypoint downloads and unpacks the dataset archive with `curl` and `tar`,
and on exit PUTs one `.tar.gz` of the artifact directory and the log. It
removes both URLs from the trainer's environment, and calls curl with `-q -g
-f` and a stall limit. A URI beats a URL for the same side.

### Changed: credentials travel as `ExAtlas.Secret` (#76)

A tracker or provider crash printed the per-call `api_key:` in its
stacktrace: OTP prints a crashed function's arguments outside
`format_status/1`. The new `ExAtlas.Secret` prints as
`#ExAtlas.Secret<redacted>`. `Orchestrator.spawn/1` and
the provider context builder in `ExAtlas.Config` wrap `api_key:` and the `:auth`, `:headers` and
`:aws_sigv4` entries of `req_options:` in it before anything else reads them.
An `api_key:` that is not a string, or a `req_options:` that is not a keyword
list, raises (or, from `spawn/1`, returns) a `NimbleOptions.ValidationError`
with `value: nil`. `inspect/1` of a `Spec.Compute` leaves out `auth`, which
holds the pod's bearer token. `Spec.Staging` holds its three credentials as
Secrets, so `inspect(staging, structs: false)` and Erlang's `~p` print none of
them. Opts that are not a keyword list with atom keys are refused by every public
function, and a `req_options: [auth: ...]` shape Req does not take is refused,
without printing them. A crashed status poll or billing read reports
`{:crashed, exception_module, stacktrace}` in `{:poll_failed, _}` and
`{:spend_reconcile_failed, _}`, with arities in place of arguments. A tracker
started with `ComputeServer.child_spec/1` directly is sealed the same way.
Tracking records drop `req_options: [aws_sigv4:
...]` as they already dropped `:auth` and `:headers`.

**Breaking for a host's own provider module:** `ctx.api_key` is an
`ExAtlas.Secret` or `nil`, and the credential entries of `ctx.req_options` are
Secrets. Read them with `ExAtlas.Secret.reveal/1` and
`ExAtlas.Config.reveal_req_options/1` where the HTTP client needs them. See
`guides/writing_a_provider.md`.

### Added: `s3:` puts storage credentials and URIs into the container (#71, slice 1 of #26)

`spawn_compute/1`, `Orchestrator.spawn/1` and `run_task/1` take `s3:` with
`endpoint`, `region`, `access_key_id`, `secret_access_key`, `session_token`,
`dataset_uri` and `artifact_uri`. RunPod pods get `AWS_ENDPOINT_URL_S3`,
`AWS_REGION`, `AWS_DEFAULT_REGION`, `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `ATLAS_DATASET_URI` and
`ATLAS_ARTIFACT_URI`. The new `ExAtlas.Spec.Staging` validates the option, and
its `inspect/1` shows no credential. Validation errors carry `key: :s3`,
`value: nil` and no value in the message. An `env:` entry that `s3:` also sets
is an error. `Orchestrator.spawn/1` returns an invalid `s3:` as an error and
keeps a valid one as a `Spec.Staging`, so no tracker stacktrace prints a
credential; the provider context builder in `ExAtlas.Config` drops `:s3`, so no provider ctx carries it.
Request opts that are not a keyword list are refused without printing them.
Tracking records and tracker crash reports drop `s3:`, and
`persist: true` with `s3:` is refused until slice 4 (#74). A provider builds its
container env from the new `ComputeRequest.container_env/1`.

### Added: a data staging guide and a reference entrypoint (#72, slice 2 of #26)

`guides/data_staging.md` describes the container contract for the variables
`s3:` sets, the stores (Tigris, R2, MinIO, AWS S3) and what ends a run before
the upload. `guides/scripts/atlas_entrypoint.sh` pulls `ATLAS_DATASET_URI`,
runs your trainer with its output copied to a log, and on exit, `INT` or `TERM`
uploads the artifact directory and `atlas.log` to `ATLAS_ARTIFACT_URI`. The
exit code is the trainer's. A failed upload is printed and changes no exit
code. Its tests run it with a stub `aws`.

### Fixed: secrets in `inspect/1` and in `env:` errors (#71)

- `inspect/1` of an `ExAtlas.Spec.Compute` no longer prints `:raw`. RunPod's
  pod body echoes the container env, so every env secret printed.
- `ComputeRequest.new/1` with an invalid `env:` returns `value: nil` and a
  message naming the variable at fault. Before, the error's `value` held the
  whole env map and its message echoed the bad value.

### Added: the cost cap reads the provider's bill (#66, slice 3 of #28)

A tracked session with `max_cost` reads the current pod's bill every
`:reconcile_spend_ms` (default 15 minutes; `false` turns it off) through
`ExAtlas.compute_spend/2`. A bill above the estimate becomes the spend, so the
cap fires sooner; a lower bill changes nothing. Each read broadcasts
`{:spend_reconciled, %{estimated_usd: e, billed_usd: b, spent_usd: s}}` or
`{:spend_reconcile_failed, error}`. A provider with no billing API is asked
once and sends neither. A raised spend rewrites the tracking record. After a
respawn the bill is compared with the replacement's spend alone; an adopted
task compares it with its whole stored spend, since the record does not say
which pod spent it. `ExAtlas.Providers.Mock` gains `compute_spend/3`, the
`:billing` capability, `set_spend/2` and `spend_requests/1`;
`ExAtlas.Orchestrator.CostMeter` gains `reconcile/3`, `new_pod/2` and
`pod_spent_usd/2`.

### Fixed

- A spent budget on a pod that reads $0 an hour fires `:cost_cap`. Before, a
  rate of 0 never armed the timer, even with the spend over the cap.
- `:heartbeat_ms`, `:status_poll_ms`, `:max_runtime_ms`, `:ready_timeout_ms`
  and `:finish_grace_ms` above 4,294,967,295 ms are refused before renting.
  Before, a value past the OTP release's timer limit crashed the tracker after
  the pod was rented. The status poll's backoff stays under the same limit.
  A tracking record written before this bound, with a longer value, adopts
  at the bound rather than failing to start a tracker.

### Added: a persisted task keeps its cost cap across a restart (#65, slice 2 of #28)

`max_cost` with `persist: true` is accepted. Tracking records are version 3
and carry `:max_cost`, `:spent_usd`, `:cost_rate` and `:cost_since_ms`. An
adopted task resumes its stored spend, and the time the node was down counts
at the last known price: a budget spent by then fails the task with
`{:task, {:failed, :cost_cap}}` at once. The tracker rewrites the record at
every new price, including the replacement's price on a respawn, before it
broadcasts `{:respawned, id}`. Version 1 and 2 records adopt uncapped, as
before, and stay on disk as they are; a node that claims one writes it back as
version 3. A host store that maps fields to columns needs the four new
columns; without them an adopted task keeps its tracker and deadline, and its
budget starts fresh. `ExAtlas.Orchestrator.CostMeter.resume/4` seeds a meter
with spend already made.

Rolling back to a build before this one leaves every record written since the
upgrade unadopted: older builds skip version 3 records, and keep them in the
store so their Reaper leaves the pods alone. End those tasks with
`stop_tracked/1` before the rollback, or delete their pods and records by hand
after it.

### Added: a cost cap on tracked sessions, `max_cost` (#64, slice 1 of #28)

`ExAtlas.Orchestrator.spawn/1` and `run_task/1` take `max_cost: dollars`. The
tracker multiplies the pod's `cost_per_hour` by the time it has run and
deletes the pod when that reaches the cap: an interactive session broadcasts
`{:terminating, :cost_cap}`, a task `{:task, {:failed, :cost_cap}}` first. A
status poll with a new price re-prices the rest of the run; a respawn carries
the spend. `info/1` gains `:max_cost` and `:spent_usd`. A provider that
reports no price gets its pod deleted and `{:error, %ExAtlas.Error{kind:
:unsupported}}`. `persist: true` with `max_cost` was refused until slice 2
(above).
`ExAtlas.Providers.Mock` spawns at `provider_opts: %{cost_per_hour: rate}` and
gains `set_cost_per_hour/2`.

### Added: serverless endpoints through the public API (#59, slice 4 of #27)

`ExAtlas.list_endpoints/1`, `get_endpoint/2` and `delete_endpoint/2` list,
read and delete RunPod serverless endpoints and return
`%ExAtlas.Spec.Endpoint{}`: `id`, `name`, `type` (`:queue`, `:load_balancer`,
`:unknown` or `nil`), `workers_min`, `workers_max`, `gpu_pools` (RunPod pool
ids such as `"ADA_24"`), `region_hints`, `network_volume_ids`, `created_at`
and `raw`. `inspect/1` leaves out `raw`, which holds the endpoint's env. A
provider without the new optional callbacks returns
`{:error, %ExAtlas.Error{kind: :unsupported}}`. RunPod declares the new
capability `:manage_endpoints`. There is no `create_endpoint`.

### Removed: the `endpoints_module` function of `ExAtlas.Providers.RunPod` (#59)

A `@doc false` accessor with no caller.

### Added: per-pod spend through the public API (#58, slice 3 of #27)

`ExAtlas.compute_spend/2` returns a `%ExAtlas.Spec.Spend{}`: one pod's
`total_usd`, `gpu_usd`, `cpu_usd` and `disk_usd`, read from RunPod's
`metadata.totals`. With no `from:` or `to:` the call sends neither `startTime`
nor `endTime`, so RunPod covers its last 30 days; the result's `from` and `to`
show the window. A `from:` or `to:` that is not a `DateTime` returns
`:validation`. A provider without the new optional `compute_spend/3` callback
returns `{:error, %ExAtlas.Error{kind: :unsupported}}`. RunPod declares the new
capability `:billing`.

### Added: templates through the public API (#57, slice 2 of #27)

`ExAtlas.list_templates/1`, `get_template/2`, `create_template/1` and
`delete_template/2` manage RunPod templates with plain options and a
`%ExAtlas.Spec.Template{}` back. `create_template/1` takes `ssh:` and
`jupyter:`; it sends them only when you set them, so RunPod's defaults (both
on) hold otherwise. `inspect/1` of a template leaves out `env` and `raw`.
A provider without the new optional callbacks returns
`{:error, %ExAtlas.Error{kind: :unsupported}}`. RunPod declares the new
capability `:manage_templates`.

### Fixed: a pod spawned from a template lost its ports and disk (#57)

`spawn_compute(template_id: ...)` sent `"ports" => []` and `"disk" => 50`,
and REST v2 applies body fields over the template's. The body now leaves
`ports` out when the spawn sets none and `disk` out when it sets no
`container_disk_gb`. A spawn without `template_id` is unchanged. Passing
`ports: []` with a template cannot clear the template's ports.

### Fixed: template and endpoint lists read only the first page (#57)

`RunPod.Templates.list/1` and `RunPod.Endpoints.list/1` now follow
`pagination.nextCursor` through `Client.list_all/3`, the pager that `Pods.list/1`
used. Both return the list of entries instead of the raw page body.

### Added: network volumes through the public API (#56, slice 1 of #27)

`ExAtlas.list_network_volumes/1`, `get_network_volume/2`,
`create_network_volume/1` and `delete_network_volume/2` manage RunPod network
volumes with plain options and a `%ExAtlas.Spec.NetworkVolume{}` back. A
provider without the new optional `ExAtlas.Provider` callbacks returns
`{:error, %ExAtlas.Error{kind: :unsupported}}`. RunPod declares the new
capability `:manage_network_volumes`, and its create call returns `:validation`
when `:region` is missing.

### Added: CI (#35)

`bin/ci` runs format, a strict compile, `mix hex.audit`, sobelow and the test
suite, and `.github/workflows/ci.yml` calls it. Sobelow fails on any Medium or
High finding, and on any finding in the callback code. Dev tooling only: no
library behaviour changes.

### Added: weekly dependency audit (#52)

`.github/workflows/audit.yml` runs `bin/audit` every Monday at 06:00 UTC. It
fetches the advisory database, then runs `mix deps.audit` (mix_audit, dev and
test only). A fetch failure or any advisory fails the run. It never runs on a
push or a pull request. Dev tooling only: no library behaviour changes.

### Fixed: a shared tracking store adopts other nodes' tasks (breaking, #46)

A `TrackingStore` backed by one shared database made every node adopt every
node's persisted tasks at boot. Two trackers then watched one pod, and a crash
or `stop_tracked/1` on node B deleted node A's pod and record.

- Records are schema version 2 and carry `:owner`, the spawning node's
  `:reap_owner` (`nil` when unset).
- A node adopts only records with its own owner. It leaves another owner's
  record in the store, never asks the provider about it, and logs one info line
  per other owner with its ids.
- The first node to adopt an unowned record (version 1, or owner `nil`) claims
  it by writing its own owner. The write is not atomic: two nodes whose
  Adopters read the store within about 5 ms of each other can both adopt it
  (measured on two peers: 19 of 20 records at 0 ms apart, 2 of 20 at 5 ms, 0 of
  20 at 20 ms or more). A rolling deploy boots nodes seconds apart.
- An invalid `:reap_owner` adopts nothing and keeps every record.
- A dead owner's pods and records stay until you delete them. No lease or
  expiry.
- **Upgrade:** a host store that maps record fields to columns needs a nullable
  `owner` column. Without it every record reads back unowned and every node
  adopts it, as before. Set `:reap_owner` on every node that shares a store.
- A v0.7.0 node beside a v0.8.0 node skips version 2 records and keeps them.

### Fixed: a graceful shutdown deletes persisted tasks (#45)

A SIGTERM deploy ran every tracker's `terminate/2`, which deleted each pod and
its tracking record, `persist: true` included. The next boot had nothing to
adopt.

- A graceful node stop (SIGTERM, `System.stop/0`, `Application.stop(:ex_atlas)`)
  keeps a `persist: true` task's pod and record, so the next boot adopts it.
  A task whose container already reported its exit code still deletes, and
  so does one whose record is missing from the store.
- Unpersisted tasks, interactive sessions, crashes, idle TTL,
  `:max_runtime_ms` and finished tasks delete as before.
- `ExAtlas.Orchestrator.stop_tracked/1` still deletes the pod and the record.
  Its tracker now ends with `{:shutdown, :stopped}`, so subscribers see
  `{:terminating, {:shutdown, :stopped}}` where they saw
  `{:terminating, :shutdown}`. A persisted task on a node stop sends
  `{:terminating, :shutdown}` and no `{:status, :terminated}`.
- `DynamicSupervisor.terminate_child/2` on
  `ExAtlas.Orchestrator.ComputeSupervisor` now counts as a node stop and
  keeps a persisted pod. Use `stop_tracked/1` to end one.
- A machine removed for good (`fly scale count` down, `fly machine destroy`)
  gets the same SIGTERM, so its persisted pods keep running untracked, with no
  `:max_runtime_ms` cap, until their containers exit or you delete them.
- On Fly, set `kill_signal = "SIGTERM"` and a `kill_timeout` of at least 30 s.
  Fly's default SIGINT halts the VM without `terminate/2`.

### Fixed: the Reaper deletes other nodes' live compute (breaking, #38)

Every node's Reaper listed the whole provider account and deleted each
prefixed pod its own node did not track. With two or more nodes on one
account, node B deleted node A's live pods, hours-long tasks included.

- New `config :ex_atlas, :orchestrator, reap_owner: "m1"`: `a-z` and `0-9`,
  1 to 32 characters, no default. Every deployment with more than one machine
  on one account must set it on every machine, unique per machine and stable
  across its restarts. On Fly: `System.get_env("FLY_MACHINE_ID")`.
- With an owner, `ExAtlas.Orchestrator.spawn/1` writes it into the pod name
  (`atlas-train-42` becomes `atlas-m1-train-42`). The returned compute, every
  respawn and the tracking record carry that name. An invalid owner returns
  `{:error, %ExAtlas.Error{kind: :validation}}` before the provider is called.
- With an owner, the Reaper deletes only untracked pods named with its own
  owner. It leaves every other prefixed pod alone and logs each once per boot.
- The Reaper reaps nothing and logs an error when the owner is invalid, when
  a node with no owner is connected to other nodes (`Node.list/0`), or when a
  connected node reports the same owner.
- A connected node that cannot report its owner (an ex_atlas older than
  v0.8.0, or no answer within 5 s) gets one warning per boot, naming it.
- New `ExAtlas.Orchestrator.Ownership`: `owner/0`, `prefix/0`, `stamp/1`,
  `classify/3`.

What the checks do not cover:

- They see connected nodes only. A node with no owner that sees no peers
  reaps as v0.7.0 did, so machines that share an account without clustering
  still delete each other's pods. An owner set on only some machines protects
  nothing.
- An owner can claim older names: a v0.7.0 pod `atlas-train-42` carries owner
  `train` to the Reaper. Pick an owner no pre-v0.8 pod name starts with.

Upgrade:

| Deployment | After upgrading |
|---|---|
| One machine on the account, no `:reap_owner` | No change. Several unclustered machines on one account also see no change, and still delete each other's pods: set an owner on each. |
| Cluster, no `:reap_owner` | The Reaper stops reaping and logs an error. Nothing is deleted; crash leftovers bill until you set an owner. |
| Cluster, `:reap_owner` set | New pods get stamped names. Pods named by v0.7.0 are left alone, with one warning each; their trackers still end them. |

A v0.7.0 node running beside a v0.8.0 node deletes the new node's pods, so a
cluster upgrades in two deploys:

1. Deploy v0.7.0 with `reap_providers: []`.
2. Deploy v0.8.0 with `:reap_owner` set and `reap_providers` restored.

## v0.7.0 — 2026-10-01

### Changed: `list_gpu_types` reads the Runpod v2 catalog (breaking, v0.7.0)

Runpod retires its GraphQL API in early 2027. `list_gpu_types(provider: :runpod)`
now reads `GET /v2/catalog/gpus` (#40). Runpod's GraphQL also rejected the old
query (`Cannot query field "stockStatus" on type "GpuType"`), so the old call
returned an error on a live key.

- One call makes two requests, `cloud=SECURE` and `cloud=COMMUNITY`, because v2
  reports stock for one cloud per request.
- `lowest_price_per_hour` is the lower list price of the clouds the GPU is on,
  even when it is out of stock. `spot_price_per_hour` is always `nil`.
- `stock` is the best level of the clouds the GPU is on.
- A GPU on neither cloud, such as Runpod's placeholder `unknown`, reads
  `lowest_price_per_hour: nil`, `stock: :unavailable`, `cloud_type: :any`.
- `GpuType.raw` is `%{"SECURE" => entry, "COMMUNITY" => entry}`, the v2 entries,
  not the GraphQL map.
- Removed: `ExAtlas.Providers.RunPod.GraphQL`, `Client.graphql/1`,
  `Client.graphql_url/0`, and telemetry `api: :graphql`.

## v0.6.0

Tagged but not published to Hex: its `list_gpu_types/1` failed on every
call. v0.7.0 carries every change below plus that fix.

### Changed: Runpod REST v2 (breaking, v0.6.0)

Runpod retires REST v1 on 2026-11-15. Every Runpod management call now goes to
`https://api.runpod.io/v2` (#34). Callers keep the same `ExAtlas` functions.
What you will see:

- `spot: true` on `:runpod` returns `{:error, %ExAtlas.Error{kind: :unsupported}}`
  before any request, and `:spot` leaves Runpod's `capabilities/0`. Runpod no
  longer sells spot pods, and v2 has no field for them. An adopted spot task that
  is preempted after the upgrade cannot respawn: it emits
  `{:respawn_failed, {:preempted, %Error{kind: :unsupported}}}`.
- A pod in Runpod's new `ERROR` state reads as `:failed`, and
  `list_compute(status: :failed)` returns it instead of always returning `[]`
  (#37).
- `list_compute` on Runpod honours `gpu:` and `region:` as well as `status:` and
  `name:`. v2 filters nothing server-side, so ExAtlas pages through every pod and
  filters locally. `gpu: :h100` returned every pod before; it now returns H100
  pods only.
- A pod spawned with no `container_disk_gb` asks for `disk: 50`, v1's default.
  v2 refused a body with no `disk` in a live probe.
- A pod spawned with no `volume_gb` gets no `/workspace` volume. A 0.5.x pod got
  a 20 GB host-local volume there. Pass `volume_gb` to keep one (10 GB minimum).
- ExAtlas adds no volume checks of its own. Runpod rejects `volume_gb` below 10,
  and a persistent plus a network volume together. The caller gets
  `{:error, %ExAtlas.Error{kind: :provider}}` carrying Runpod's `detail`.
- `provider_opts` for Runpod now take v2 keys and merge into the body deeply:
  `%{"gpu" => %{"minCudaVersion" => "12.1"}}` keeps `gpu.id`. `Compute.raw` is the
  v2 pod body.
- Runpod serverless endpoints, network volumes and billing use their v2 paths
  (`/serverless`, `/network-volumes`, `/billing/serverless`,
  `/billing/network-volumes`).
- `Compute.created_at` reads the pod's `startedAt`, then `createdAt`.

Upgrade notes:

- A pod spawned by 0.5.x carries the v1 URL in its self-delete trap. If one is
  still running after 2026-11-15, its self-delete fails, and `:max_runtime_ms` or
  `terminate/2` (now v2) ends it.
- Pods created through v1 keep working: v2 resolves their ids, and `DELETE`
  answers 204 (live probe, 2026-09-30). `TrackingStore` adoption needs no change.
- A command that exits leaves the pod `RUNNING` on v2, as on v1: Runpod restarts
  the container. Self-termination and `:max_runtime_ms` stay the only ways a task
  ends.

### Fixed

- Provider errors read RFC 9457 `detail` and string `errors`, so a Runpod v2
  failure carries Runpod's own words.
- A pod create is never retried. A create that timed out or answered 5xx could
  rent a second pod that nothing tracked.
- Request telemetry no longer carries the query string, which held the GraphQL
  `api_key`.
- The Reaper keeps `:provisioning` pods in its orphan list, as v1's
  `desiredStatus=RUNNING` filter did.

### Added

- **Re-adoption instead of reaping after a restart** (#23). Nothing in the
  orchestrator survived the VM: `ComputeRegistry` is in-memory and
  `ComputeServer` is `restart: :temporary`, so a deploy emptied the registry
  while the pods kept running — and the Reaper, seeing an old,
  prefix-matching, untracked pod, terminated it. For a task that is hours of
  GPU spend destroyed by a routine deploy. `:reap_grace_ms` never covered it:
  it spares resources that are *young*, and a pod three hours into a training
  run is not.

  Opt a task in per spawn:

      ExAtlas.Orchestrator.run_task(
        provider: :runpod,
        gpu: :h100,
        image: "ghcr.io/acme/trainer:latest",
        command: ["/app/train.sh"],
        name: "atlas-train-#{run.id}",
        max_runtime_ms: :timer.hours(6),
        persist: true
      )

  `spawn/1` records the id, the scrubbed opts and a **wall-clock**
  `spawned_at_ms`; at the next boot `ExAtlas.Orchestrator.Adopter` reads them
  back, asks the provider which ids still exist, and rebuilds a tracker for
  each one.

  **The deadline survives.** `deadline_at_ms` is `System.monotonic_time/1` and
  is meaningless in a new VM, so an adopted task recomputes what is *left* of
  `:max_runtime_ms` from the wall-clock anchor. A six-hour task that was down
  for seven hours fires `:max_runtime` immediately rather than silently
  starting a second six hours. The `on_failure: {:respawn, n}` budget and a
  landed `finish` report carry across for the same reason.

  **`ExAtlas.Orchestrator.TrackingStore` is a behaviour**, mirroring
  `ExAtlas.Fly.TokenStorage`: five callbacks, a shared conformance suite in
  `test/support`, and `config :ex_atlas, :orchestrator, tracking_store:
  MyApp.AtlasStore` to swap in your own. `TrackingStore.Dets` is the
  zero-config default — but note that **a Fly machine with no attached volume
  gets a fresh filesystem on every deploy**, which makes the DETS default
  silently useless there. Mount a volume and set `:storage_path`, or supply a
  store backed by something already durable.

  **The Reaper now asks "Registry *or* store?"** and starts gated: with a store
  configured it terminates nothing until the Adopter signals that adoption has
  settled, which closes the boot-time race explicitly rather than relying on
  the first tick being scheduled an interval out. If the store cannot be read
  — a corrupt DETS file, a database that will not answer — the Adopter says so
  and **reaping is disabled for the entire boot**: a node that cannot account
  for which running compute is its own must never issue a DELETE.

  Deliberately scoped out, and documented as such:

    * **Tasks only.** `persist: true` requires `mode: :task`, refused at the
      same boundary that validates every other tracking option. An interactive
      session's `compute.auth.token` is never written down, so an adopted one
      would be a pod nobody can authenticate to, billing for another idle TTL.
    * **Single node.** A node adopts only ids it recorded itself. "Node A died,
      node B takes over" needs a shared store plus leases with an owner column
      and expiry — a different ticket. The Reaper's existing multi-node hazard
      (#38) is unchanged either way.
    * **No `reap_action` flag.** The ticket proposed one alongside the store;
      with the store authoritative it is redundant, and per-spawn intent is
      one boolean.

  Secrets never reach disk: `:api_key` and friends are scrubbed, `:req_options`
  loses its `:auth`/`:headers`, and the raw preshared key
  `ExAtlas.Auth.Token`'s moduledoc promises is never stored has no field to be
  stored in. `:env` *is* persisted verbatim, because a respawn without it would
  silently run broken work — extend `scrub_keys:` if you inject secrets that
  way.

  Everything is opt-in. With `persist: false` (the default) and
  `tracking_store: false`, behaviour is exactly what it was.

- **`await_ready/2`: block until a compute is usable** (#22). `spawn_compute/1`
  returns when the provider accepts the rental, minutes before the container
  can serve traffic, and every caller was writing the same spawn → poll →
  check-status loop by hand.

  Two entry points, one result shape (`t:ExAtlas.await_result/0`):

      # Untracked — a bare spawn, a script, a mix task. Polls get_compute/2.
      ExAtlas.await_ready(id, provider: :runpod, timeout_ms: 120_000)

      # Tracked — subscribes to the ComputeServer's existing status stream.
      ExAtlas.Orchestrator.await_ready(id, timeout_ms: 120_000)
      # {:ok, %Compute{status: :running}}
      # | {:error, {:timeout, last_seen_compute_or_nil}}
      # | {:error, {:dead, :failed | :stopped | :terminated | :vanished | :preempted, compute_or_nil}}

  What the ticket asked for that is no longer needed: it also proposed that
  `ComputeServer` poll upstream and broadcast `{:status, :running}` when the
  pod is actually up. #24 shipped exactly that, so a *tracked* compute already
  announces readiness. `Orchestrator.await_ready/2` therefore subscribes to
  that stream rather than opening a second poll — awaiting ten pods costs the
  provider nothing beyond the ten polls already running — and reads the
  tracker's state after subscribing so a resource that came up in between is
  not missed. An untracked id falls back to the polling path, so one call
  covers both.

  `{:poll_failed, _}` does not resolve the wait: a 5xx, a rate limit or a
  socket error is "we could not tell", so the wait backs off (reusing
  `UpstreamStatus.next_interval_ms/3`) and continues to its timeout. Timing out
  terminates nothing and hands back the last observed `Compute`, per the
  ticket. Readiness means observed `:running` and deliberately *not* "running
  with ports populated" — a port-less `run_task/1` pod would never satisfy
  that.

  Across an `on_failure: {:respawn, n}` respawn the wait follows the
  replacement on the *original* deadline. Getting that right meant fixing a
  real ordering bug the tests found: `ComputeServer` broadcasts the death cause
  *before* deciding whether to respawn, so a naive wait reported a preempted-
  then-replaced session as over. A cause is now held until the tracker confirms
  it by stopping.

- **Pod→host callback boundary: progress, logs and exit codes** (#25).
  ExAtlas gains its first *inbound* external boundary. A running container can
  now POST progress, stream log lines, and declare its exit code before it
  goes, and the orchestrator relays all three on the existing
  `"compute:<id>"` topic as `{:progress, payload}`, `{:log, payload}` and
  `{:task_report, %{exit_code: n}}`.

  New modules: `ExAtlas.Callback` (framework-free core — `verify/1`,
  `ingest/3`, `prepare/1`), `ExAtlas.Callback.Plug` (the shipped HTTP
  boundary, behind a new **optional** `:plug` dependency),
  `ExAtlas.Callback.Token` (stateless signed credential) and
  `ExAtlas.Callback.Limiter` (per-task, per-kind ETS token bucket).

  Turn it on with `callback: "https://app.example.com/atlas/cb"` on
  `spawn/1`/`run_task/1` (or `config :ex_atlas, :callback, base_url: ...`),
  a `secret:` in the same config block, and
  `forward "/cb", ExAtlas.Callback.Plug` in your router.

  Why a `task_id` and not the compute id, as the ticket proposed: RunPod
  assigns the compute id in the `POST /pods` *response*, so nothing can bind a
  token to it while the container environment is still being built. The task id
  is minted before the provider call, and it survives an
  `on_failure: {:respawn, n}` swap, where a compute id would not.

- **`:completed` is now provable, and the spot ambiguity is closed** (#25).
  `ExAtlas.Orchestrator.TaskOutcome.classify/3` takes the recorded report:
  a clean exit turns an inferred completion into a proven one, a non-zero exit
  becomes `{:task, {:failed, {:exit_code, n}}}` — the existing failure shape,
  so no subscriber breaks — and a preemption observed after a clean report
  reads as `:completed`. A compute that reported `finish` is never respawned,
  so `on_failure: {:respawn, n}` can no longer re-run work that already
  finished. With no report, `classify/3` is byte-identical to `classify/2`.

- **`:finish_grace_ms` (default 60s) fixes `self_terminate: false`** (#25).
  A one-shot armed by the first report. When the report lands but the resource
  never disappears — a skipped trap, an image without `curl`, a `DELETE` that
  failed — the task finishes on the report and teardown issues the `DELETE`
  that stops the meter. Those tasks could previously only ever end as
  `:timed_out`.

- **`ExAtlas.Orchestrator.run_task/1` — run a container to completion** (#21).
  The third compute shape, alongside interactive per-user pods and serverless
  jobs: run this image with this command until it exits, report the outcome,
  destroy the resource. Broadcasts `{:task, :completed}`,
  `{:task, :timed_out}` or `{:task, {:failed, reason}}` before the existing
  `{:terminating, _}` / `{:status, :terminated}` pair.

  It is the same `ComputeServer` in `mode: :task`, not a second server: that
  module already owns `trap_exit` plus a `terminate/2` that guarantees the
  `DELETE`, the shutdown budget that lets it finish, the offloaded status
  poll, "uncertainty never tears a resource down", and registry re-keying on
  respawn. Task mode adds `:max_runtime_ms` and `:ready_timeout_ms` timers,
  removes the idle clock, and defers the one mode-dependent decision to the
  new pure `ExAtlas.Orchestrator.TaskOutcome`.

- **`:command` and `:self_terminate` on `ExAtlas.Spec.ComputeRequest`** (#21).
  `:command` maps to RunPod's `dockerStartCmd`, previously reachable only via
  the `:provider_opts` escape hatch. `:self_terminate` (default `true`) wraps
  it in a shell that deletes the resource when the command ends, using the
  `RUNPOD_POD_ID` and pod-scoped `RUNPOD_API_KEY` RunPod injects, with a
  `trap` so a crash cleans up too.

  This is not a convenience. RunPod's REST v1 `Pod` schema exposes no
  container state — no `runtime` object, no `currentStatus`, no exit code —
  and `desiredStatus` is a *desired* state that only changes when someone asks.
  So a pod whose `dockerStartCmd` has exited keeps reporting `RUNNING` and
  keeps billing, and polling can never notice. Self-termination is the only
  source of a normal-exit signal; `:max_runtime_ms` is the only cover for the
  cases where nothing in the container can run (SIGKILL, OOM kill, a hung
  process, a failed image pull, `self_terminate: false`). Both are required
  and neither is sufficient alone, so `run_task/1` defaults both on.

- **`ExAtlas.Orchestrator.info/1` reports `:mode` and
  `:max_runtime_remaining_ms`** (#21), so a UI can show how much of a task's
  wall-clock budget is left.

- **`:self_terminate` capability atom**, reported by RunPod.

### Fixed

- **`created_at` is populated for RunPod pods again** (#21) —
  `Translate.parse_created_at/1` read `pod["createdAt"]`, which does not exist
  on RunPod's REST v1 `Pod` schema; its only machine-readable timestamp is
  `lastStartedAt`. So `Compute.created_at` was `nil` for every RunPod pod,
  `Reaper.young?/3` fell through to its `false` catch-all, and the
  `:reap_grace_ms` window shipped in #24 was inert against the one provider it
  was written for — leaving the spawn race it exists to close wide open.

- **Request options are routed by request type** (#21) — `spawn_compute/1` and
  `run_job/1` split their options against a single shared key list holding the
  union of both request structs' fields, so each handed the other's options to
  its own builder and `NimbleOptions` raised on a key merely addressed
  elsewhere: `spawn_compute(gpu: :h100, mode: :async)` died on
  `unknown options [:mode]`.

### Removed

- The unreachable `desiredStatus: "FAILED"` clause in RunPod's pod-status
  translation. The enum is exactly `RUNNING | EXITED | TERMINATED`; an
  unclassifiable status now falls through to `:provisioning`, which
  `UpstreamStatus` counts as alive rather than as a death.

### Security

- The pod callback endpoint is internet-reachable and every byte on it comes
  from a container ExAtlas does not control, so the library ships the
  dangerous parts rather than documenting them (#25): body caps applied by
  `read_body/2` **before** any JSON decode and without consulting the
  attacker-written `content-length`; constant-time verification via
  `Plug.Crypto`; a per-task, per-kind rate limit with swept buckets; distinct
  401/410/413/429 responses, none of which reveals to an unauthenticated
  caller whether a task id exists; `send` rather than `GenServer.call`, so a
  web request can never block on the orchestrator's mailbox; no atom ever
  created from client input; and no response body that echoes the token.

- Callback URLs are validated at the `spawn/1` seam, *before* the provider is
  called, and a non-`https`, loopback, RFC 1918, link-local or `.local` host is
  refused unless `allow_insecure_callback: true` (#25). Validating after the
  resource existed would leak a live, billing pod behind a raise, and a
  callback that silently never arrives is worse than no callback at all.

- `:max_runtime_ms` remains authoritative: a pod cannot extend its own budget
  by staying quiet or by talking. `progress` deliberately does **not**
  `touch/1`, so a compromised pod cannot defeat its own idle TTL (#25).

## v0.5.0 — unreleased

Closes all remaining audit items. Library is now at feature parity with
the audit recommendations.

### Fixed

- **A malformed pod body no longer raises** (#24) —
  RunPod's `get_compute` piped the response body straight
  into a translator guarded on `is_map/1`, so a 200 carrying `null` raised a
  `FunctionClauseError` at the call site. It now returns an
  `%ExAtlas.Error{kind: :provider}`, which matters because the status poller
  runs this call in a loop inside a GenServer.

- **Provider-specific options reach the provider ctx** (#20) —
  `ExAtlas.Config.build_ctx/2` only kept `:provider`, `:api_key`,
  `:base_url` and `:req_options` and dropped everything else, so the
  documented `ExAtlas.get_job(id, provider: :runpod, endpoint: "abc123")`
  (and `cancel_job/2`, `stream_job/2`) could never succeed — RunPod reads
  `:endpoint` from the ctx and returned a `:validation` error every time.
  Remaining options are now passed through to the ctx verbatim; the four
  options ExAtlas resolves itself still win.

### Added

- **Upstream status polling** (#24) — the `ComputeServer` heartbeat only ever
  compared local timestamps, so a pod that died on the provider's side (host
  failure, crash-looping image, spot preemption) was never noticed:
  subscribers kept believing the session was healthy until the idle TTL fired
  and ExAtlas tried to terminate something long gone. Each tracker now runs a
  second, independent clock — `:status_poll_ms`, default `60_000`, `false` to
  disable — that calls `get_compute/2`, broadcasts upstream status changes
  while the resource is alive, and broadcasts the cause of death before
  stopping.

  - New `{:status, :failed | :stopped | :vanished | :preempted}` and
    `{:poll_failed, error}` events. **A failed poll is not a death**: only a
    404 means the resource is gone, so 5xx, rate limits, socket errors,
    malformed bodies and bad API keys back the poller off instead of ending
    the session.
  - `:preempted` is *inferred* — no provider publishes a preemption signal —
    for resources spawned with `spot: true` that stop, are terminated, or
    vanish unbidden.
  - Optional `on_failure: {:respawn, max_attempts}` replaces a preempted
    resource from the same opts, terminating the old one if the provider still
    has it, re-keying the tracker under the new id and emitting
    `{:respawned, new_id}` on the old topic. The id travels alone — the
    replacement's URL and bearer token are read back with
    `ExAtlas.Orchestrator.info/1` rather than broadcast.
  - The poll itself runs in a supervised task rather than in the tracker's
    callback, so a slow or hanging provider can't delay `touch/1`, `info/1` or
    — the expensive one — teardown, which has to win the race to issue its
    `DELETE`. Raises on the poll path are reported as `{:poll_failed, _}` too:
    the tracker never tears a resource down on uncertainty.
  - `:reap_grace_ms` (default: one reap interval) keeps the Reaper off
    resources too young to have a tracker yet — every resource is created
    upstream before it is registered.
  - Tracking options are validated at the `ExAtlas.Orchestrator.spawn/1`
    boundary, before the provider is asked for anything.
  - `ExAtlas.Orchestrator.UpstreamStatus` exposes the classification and the
    jittered/backing-off poll schedule as a standalone primitive.
  - `ExAtlas.Providers.Mock.set_status/2` and `forget/1` let consumers
    simulate upstream deaths in their own tests.

- **`ExAtlas.Fly.Supervisor`** (E3) — top-level supervisor for the Fly
  sub-tree, exposed as a `child_spec/1` so hosts can embed ExAtlas under
  their own supervision tree. `ExAtlas.Application` delegates to its
  `fly_children/0` to avoid duplication.
- **`ExAtlas.Fly.Tokens.refresh/1`** (E5) — atomic invalidate-then-acquire.
  Equivalent to `invalidate/1` + `get/1` but runs under a single
  GenServer call on the AppServer, closing the race where a concurrent
  caller acquires between the two.
- **`ExAtlas.Fly.Dispatcher.subscribe_with_backpressure/2`** (E6) — opt-in
  eviction watchdog. Monitors the subscriber's message queue and signals
  an eviction via `{:ex_atlas_fly_backpressure_evict, topic}` if the
  queue exceeds a configurable threshold.
- **Proactive soft-expiry refresh** (E7) — `ExAtlas.Fly.Tokens.AppServer`
  schedules a background refresh `:soft_expiry_lead_seconds` (default 3600)
  before a cached token's `expires_at`. Avoids the expiry cliff where
  every caller around expiry hits the CLI at once.
- **Monorepo discovery** (M4) — `ExAtlas.Fly.Deploy.discover_apps/2`
  now accepts a `:max_depth` option. Default `1` preserves current
  behavior; set higher for `apps/<name>/fly.toml` layouts.
- **Streamer shutdown signal** (L5) — the Streamer sends a final
  `{:ex_atlas_fly_logs_stopped, app_name}` on its topic when it
  terminates, so subscribers can unsubscribe themselves from the
  framework-agnostic dispatcher.

### Changed

- **`ExAtlas.Fly.Deploy.deploy/2`** (M5) — now returns
  `{:error, {:fly_error, :not_found, _}}` when `fly` is not on `PATH`,
  matching `stream_deploy/3`. Previously raised `ErlangError` from
  `System.cmd/3` on missing executables.
- **`ExAtlas.Fly.Deploy.parse_app_name/1`** (L3) — tightened regex:
  quoted values must not contain whitespace (pre-fix `app = "my app"`
  returned `{:ok, "my"}`). Still accepts unquoted values and
  whitespace-separated inline comments on the `app =` line.
- **`ExAtlas.Fly.Logs.Streamer` L7 race fix** — until the first
  subscriber registers via `subscribe_pid/2`, the Streamer advances its
  cursor silently without dispatching. Previously the very first poll
  could fire before a caller's `subscribe_pid/2`, dropping the first
  batch onto a zero-subscriber topic.
- **`ExAtlas.Fly.Logs.Streamer.subscribe/2`** (L4) — `project_dir` is
  no longer required. New `subscribe/2` arity takes keyword options
  only; `subscribe/3` stays for backward compatibility with the old
  positional signature.
- **`ExAtlas.Fly.Tokens.AppServer` config resolution** (M8, M9) —
  `:fly_config_file_enabled` and `:cli_timeout_ms` are now resolved
  once at AppServer `init/1` rather than on every `handle_call`. Uses
  the consistent `Keyword.get(config, :key, default)` pattern.
- **`ExAtlas.Fly.Tokens.AppServer` structured logging** (E4) —
  remaining `Logger.warning` interpolations for CLI failures now use
  metadata (`app:`, `exit_code:`, `output:`, `timeout_ms:`) instead of
  interpolated strings.
- **`ExAtlas.Fly.TokenStorage.Dets` mkdir fallback** (M6) — when the
  explicitly-configured `:storage_path` is not writable, falls back to
  `System.tmp_dir!/0` with a `:warning` log, rather than crashing on
  `File.mkdir_p!/1`. Previously only the default path had the fallback.
- **`unless` → `if` throughout `deploy.ex`** (L1).
- **`deploy/2` and `stream_deploy/3` error shape typed explicitly**
  (L2) — new `deploy_error` type in `ExAtlas.Fly.Deploy` documents
  the three `:fly_error` reason variants (`:not_found`, `:timeout`,
  `non_neg_integer()`).

### Installer

- **`mix ex_atlas.install` runtime.exs example** (M2) — the post-install
  notice now includes a `runtime.exs` pattern for containerized deploys
  that want to override `:storage_path` via an environment variable.

### Dispatcher docs (H7)

- Added a subsection describing dispatch serialization semantics and
  pointing hosts with large fan-out at `:phoenix_pubsub` mode. The
  per-subscriber `send/2` loop in `:registry` mode is documented as
  intentional for the typical log-streaming / deploy workload.

## v0.4.1 — unreleased

### Changed — Async token persist (closes audit H3)

- `ExAtlas.Fly.Tokens.AppServer` now offloads cached-token storage
  writes to a supervised `Task` under a new
  `ExAtlas.Fly.Tokens.TaskSupervisor` child. The AppServer's
  `handle_call` replies as soon as ETS is updated; `:dets.sync`
  happens in the background.
- Net effect: a slow storage write for one app no longer blocks that
  app's own subsequent token requests (and never blocked other apps',
  post-E1). Callers get the token with latency gated on ETS + cmd_fn
  only. Audit finding H3.
- **Manual-token persist stays synchronous.** Manual tokens are not
  re-acquirable, so `ExAtlas.Fly.Tokens.set_manual/2` still returns
  `{:error, {:persist_failed, reason}}` when storage raises — the
  caller must know if persist failed.
- Persist failures on the cached path continue to log at `:error`
  level with `{app, reason}` metadata, now emitted from the task
  rather than the mailbox (contract preserved, emission point
  moved).

### Added

- `ExAtlas.Fly.Tokens.TaskSupervisor` is a new child of
  `ExAtlas.Fly.Tokens.Supervisor`, ordered after `ETSOwner` and
  before the `DynamicSupervisor`. Tests can inject a custom name
  via `:task_sup` on `Tokens.Supervisor.start_link/1`.

## v0.4.0 — unreleased

### Changed — Per-app Fly tokens (audit E1; closes H3, H4)

- Replaced the singleton `ExAtlas.Fly.Tokens.Server` with a per-app
  `ExAtlas.Fly.Tokens.AppServer` supervised under
  `ExAtlas.Fly.Tokens.Supervisor`. Token resolution for one app no
  longer blocks resolution for any other. A thundering herd of CLI
  acquisitions (e.g. post-VM-restart across N apps) now runs in
  parallel rather than serialized behind a single mailbox.
- `ExAtlas.Fly.Tokens.Server` is **removed**. The documented public API
  (`ExAtlas.Fly.Tokens.{get/1, invalidate/1, set_manual/2}`) is
  unchanged and remains the stable entry point.
- Shared ETS table (`:ex_atlas_fly_tokens`) is now `:public` and owned
  by `ExAtlas.Fly.Tokens.ETSOwner`, outliving individual AppServer
  crashes. A crashed AppServer restarts with its cache intact; an
  ETSOwner crash rebuilds the whole tokens subtree via `:rest_for_one`
  (Registry survives, DynamicSupervisor + every AppServer restart).
- Concurrent `Tokens.get/1` calls for the **same** app coalesce at the
  AppServer mailbox — only the first-in-line caller invokes the CLI;
  subsequent callers re-check ETS (filled by the first) before
  descending the resolution chain.

### Added

- `[:ex_atlas, :fly, :token, :acquire]` `:stop` metadata gains a new
  `:acquirer` field — `:facade` for pure ETS fast-path hits (no
  AppServer consulted) or `:app_server` for slow-path / coalesced
  resolutions. Existing handlers that match only on `:source` are
  unaffected. See `guides/telemetry.md` for the diagnostic interpretation.
- `ExAtlas.Fly.Tokens.Supervisor.whereis_app_server/2` and
  `resolve_app_server/2` — lookup / resolve-or-start helpers.
  Primarily for tests.

## v0.3.1 — 2026-04-22

### Added — Telemetry for Fly platform ops

- `[:ex_atlas, :fly, :token, :acquire]` span events around every
  `ExAtlas.Fly.Tokens.get/1` call. `:stop` metadata includes `source:`
  (`:ets` / `:storage` / `:config` / `:cli` / `:manual` / `:none`) so
  operators can measure cache-hit rate and acquisition-path latency.
- `[:ex_atlas, :fly, :logs, :fetch]` span events around
  `ExAtlas.Fly.Logs.Client.fetch_logs/3`. Metadata: `{app, status, count}`.
  Inherited automatically by `fetch_logs_with_retry/2`.
- `[:ex_atlas, :fly, :deploy, :line]` (one per non-empty output line) +
  `[:ex_atlas, :fly, :deploy, :exit]` (one per deploy termination) from
  `Deploy.stream_deploy/3`. Line content is deliberately excluded — Fly
  build output can contain bearer tokens.

See `guides/telemetry.md` for the full event reference.

### Added — Shared TokenStorage conformance suite

- `ExAtlas.Fly.TokenStorageConformance` — a `use`-able ExUnit macro that
  any `TokenStorage` implementation can adopt to inherit the full
  `get/put/delete` contract coverage across `:cached` and `:manual`
  keys. Mirrors the existing `ExAtlas.Test.ProviderConformance` pattern.
- `Memory` and `Dets` both run under the shared suite now, so any
  future adapter (Redis, Postgres, vault) can prove parity with one
  `use` line.

## v0.3.0 — unreleased

### Changed — Fly token / streamer return contracts

- `ExAtlas.Fly.Tokens.set_manual/2` (and `Tokens.Server.set_manual_token/3`)
  now return `:ok | {:error, {:persist_failed, reason}}` instead of always
  `:ok`. Manual tokens are not re-acquirable, so storage failures must be
  surfaced rather than silently logged. Callers that pattern-match on
  `:ok` should handle the error tuple.
- `ExAtlas.Fly.subscribe_logs/3` (and `Streamer.subscribe/3`) now return
  `:ok | {:error, :no_streamer}` when no streamer can be resolved
  (e.g. the Fly sub-tree is disabled). Previously this case returned a
  silent `:ok` with no messages ever arriving.

### Fixed — Hardening round

- `ExAtlas.Fly.Tokens.Server` `persist/3` (cached path) now returns
  `:ok | {:error, {:persist_failed, reason}}` and logs failures at
  `:error` level with `{app, reason}` metadata instead of `:warning`
  with interpolated strings. ETS still holds a fresh token for the
  session, but a silent storage outage is now operator-visible.
- `ExAtlas.Fly.Dispatcher` `:mfa` mode wraps the host MFA in
  `try/rescue/catch` so a raising MFA no longer takes down the caller
  (most commonly the log Streamer, whose crash drops the pagination
  cursor). Failures are logged at `:error` level with the topic and MFA
  identity.
- `ExAtlas.Fly.TokenStorage.Dets` refuses to auto-recreate a corrupt
  `manual.dets` file on startup — manual tokens are bearer credentials
  that are NOT re-acquirable. Returns `{:stop, {:manual_dets_corrupt,
  path, reason}}` and preserves the file for operator intervention. The
  cached-token path still recreates (re-acquirable, perf regression only).
- `ExAtlas.Fly.TokenStorage.Dets` now `chmod`s the storage dir to `0700`
  and each DETS file to `0600` after open. Default umask on typical
  Linux/macOS left token files world- or group-readable.
- `mix ex_atlas.install` surfaces `.gitignore` update failures as an
  `Igniter.add_notice` with the exact line the user must add manually;
  previously the installer silently swallowed the exception and moved on.
- `ExAtlas.Fly.TokenStorage.Memory` (test support) now catches `:exit`
  from pre-init reads and returns `:error`, matching the Dets `rescue
  ArgumentError` semantics so the test double is faithful to prod.

### Added

- `ExAtlas.Fly.TokenStorage.Dets.start_link/1` accepts `:name`,
  `:cached_table`, `:manual_table` opts so custom-supervised /
  per-test instances are possible alongside the default singleton.
- First test coverage for `ExAtlas.Fly.Dispatcher`, `TokenStorage.Dets`,
  `TokenStorage.Memory`, and the `Streamer.subscribe/3` silent-failure
  path.

## v0.2.0 — unreleased

### Fixed

- `ExAtlas.Fly.Logs.Client.next_start_time/1` no longer crashes the
  Streamer when a log entry has a `nil` or malformed ISO-8601 timestamp;
  unparseable entries are logged and skipped.
- `ExAtlas.Fly.Deploy.stream_deploy/3` cleans both the activity and
  absolute timers symmetrically across all exit branches, so no stray
  `{:deploy_*_timeout, _}` message leaks into a long-lived caller's
  mailbox. Exposes `:activity_timeout_ms` / `:max_timeout_ms` options.
- `ExAtlas.Fly.Tokens.Server` now implements `terminate/2` to delete its
  named ETS table, avoiding an `ArgumentError` on supervisor restart,
  and defensively reclaims an existing table in `init/1`.
- `ExAtlas.Fly.Tokens.Server` shuts down a hung `fly` CLI task with
  `:brutal_kill` so the configured `cli_timeout_ms` is actually the
  mailbox blocking time, not `cli_timeout_ms + 5_000`.
- `ExAtlas.Fly.Logs.StreamerSupervisor` uses `:rest_for_one` with a
  generous restart budget on the `DynamicSupervisor` so one app's
  misbehaving streamer no longer tears down the registry and every
  other app's pagination cursor.

### Added — Fly.io platform operations

- `ExAtlas.Fly` top-level facade for Fly.io platform ops:
  `discover_apps/1`, `deploy/2`, `stream_deploy/3`, `subscribe_logs/3`,
  `unsubscribe_logs/1`, `subscribe_deploy/1`, `unsubscribe_deploy/1`.
- `ExAtlas.Fly.Deploy` — `fly deploy --remote-only` with 15 min timeout
  (`deploy/2`) and Port-based streaming (`stream_deploy/3`) with a
  5 min activity timer and 30 min absolute cap. Dispatches
  `{:ex_atlas_fly_deploy, ticket_id, line}` on each line.
- `ExAtlas.Fly.Logs.Client` — `Req`-backed client for the Fly Machines
  log API (NDJSON, cursor pagination, automatic 401 retry).
- `ExAtlas.Fly.Logs.Streamer` + `StreamerSupervisor` — per-app GenServer
  that polls the log API every 2 s, dispatches
  `{:ex_atlas_fly_logs, app, entries}`, and stops once all subscribers
  have disconnected (monitor-based).
- `ExAtlas.Fly.Tokens` + `ExAtlas.Fly.Tokens.Server` — cache-first token
  resolver. Order: ETS → `TokenStorage` → `~/.fly/config.yml` →
  `fly tokens create readonly` → manual override.
- `ExAtlas.Fly.TokenStorage` — pluggable behaviour for durable token
  persistence. Default impl `ExAtlas.Fly.TokenStorage.Dets` is
  zero-config and survives VM restarts.
- `ExAtlas.Fly.Dispatcher` — framework-agnostic broadcast. Modes:
  `:registry` (default, zero-dep), `:phoenix_pubsub` (when host uses
  Phoenix), or `{:mfa, {m, f, a}}` custom routing.
- `ExAtlas.Application` now supervises the Fly sub-tree by default.
  Disable with `config :ex_atlas, :fly, enabled: false`.

### Added — Igniter installer

- `mix ex_atlas.install` — adds sensible `config :ex_atlas, :fly` defaults,
  creates the DETS storage directory, wires `phoenix_pubsub` when
  available.
- `mix ex_atlas.upgrade` — runs per-version upgraders (no-op for 0.1.x
  → 0.2.0; reserved for future migrations).

### Changed

- Description and package scope broadened from "GPU/compute SDK" to
  "infrastructure SDK".
- `ExAtlas.Application`'s Fly sub-tree boots by default. The existing
  orchestrator sub-tree is still opt-in via `start_orchestrator: true`.

## v0.1.0 — unreleased

Initial public release.

### Added — Core API

- `ExAtlas` top-level provider-agnostic module (`spawn_compute/1`,
  `get_compute/2`, `list_compute/1`, `stop/2`, `start/2`, `terminate/2`,
  `run_job/1`, `get_job/2`, `cancel_job/2`, `stream_job/2`,
  `list_gpu_types/1`, `capabilities/1`).
- `ExAtlas.Provider` behaviour defining the contract every provider
  implements.
- `ExAtlas.Config` — per-call > app-env > env-var resolution for provider
  and API key. Supports user-defined provider modules passed directly by
  name (no registration needed).
- `ExAtlas.Error` — canonical error struct with `:kind` atoms
  (`:unauthorized`, `:not_found`, `:rate_limited`, `:timeout`,
  `:unsupported`, `:validation`, `:provider`, `:transport`, `:unknown`)
  and `from_response/3` for translating HTTP responses.

### Added — Normalized specs

- `ExAtlas.Spec.ComputeRequest` — input to `spawn_compute/1` with
  `NimbleOptions`-validated fields, `:provider_opts` escape hatch.
- `ExAtlas.Spec.Compute` — normalized compute resource response.
- `ExAtlas.Spec.JobRequest` / `ExAtlas.Spec.Job` — serverless jobs.
- `ExAtlas.Spec.GpuType` — catalog entry with pricing + stock.
- `ExAtlas.Spec.GpuCatalog` — stable canonical GPU atoms
  (`:h100`, `:a100_80g`, `:rtx_4090`, ...) mapped to each provider's
  native identifier.

### Added — Providers

- `ExAtlas.Providers.RunPod` — full implementation covering REST management
  (pods, endpoints, templates, network volumes, billing), serverless
  runtime (async/sync/stream job submission, status, cancel), and the
  legacy GraphQL pricing catalog. Built on `Req`.
  - Sub-modules: `Client`, `GraphQL`, `Pods`, `Endpoints`, `Jobs`,
    `Templates`, `NetworkVolumes`, `Billing`, `Translate`.
- `ExAtlas.Providers.Mock` — in-memory ETS-backed provider for tests and
  demos. Implements every callback.
- `ExAtlas.Providers.Stub` macro — shared base for placeholder providers.
- `ExAtlas.Providers.Fly`, `ExAtlas.Providers.LambdaLabs`,
  `ExAtlas.Providers.Vast` — placeholder modules reserving atoms and
  capability lists for v0.2 / v0.3.

### Added — Auth

- `ExAtlas.Auth.Token` — cryptographically random 256-bit bearer tokens
  with SHA-256 hashing and constant-time comparison (`Plug.Crypto`).
- `ExAtlas.Auth.SignedUrl` — S3-style HMAC-SHA256 signed URLs with
  expiry, for media streams and WebSockets that can't set headers.
- Auto-injection: `auth: :bearer` on `spawn_compute/1` mints a token,
  injects it into the pod as `ATLAS_PRESHARED_KEY`, and returns the
  handle in `compute.auth`.

### Added — Orchestrator (opt-in)

- `ExAtlas.Orchestrator` — high-level API (`spawn/1`, `touch/1`, `info/1`,
  `stop_tracked/1`, `list_ids/0`).
- `ExAtlas.Orchestrator.ComputeServer` — one GenServer per tracked
  resource, traps exits, enforces `:idle_ttl_ms`, broadcasts state
  changes via `ExAtlas.Orchestrator.Events`.
- `ExAtlas.Orchestrator.ComputeSupervisor` (`DynamicSupervisor`) +
  `ExAtlas.Orchestrator.ComputeRegistry` (`Registry` with `:via` lookup).
- `ExAtlas.Orchestrator.Reaper` — periodic reconciliation; terminates
  orphans whose `:name` matches the configurable safety-prefix.
- `ExAtlas.Application` starts the tree only when
  `config :ex_atlas, start_orchestrator: true`; library-only users pay
  nothing.
- Phoenix.PubSub broadcasts on `"compute:<id>"` topic as
  `{:atlas_compute, id, event}` for `{:status, s}`,
  `{:heartbeat, ms}`, `{:terminating, reason}`,
  `{:terminate_failed, err}` events.

### Added — Phoenix LiveDashboard integration

- `ExAtlas.LiveDashboard.ComputePage` — drop-in
  `Phoenix.LiveDashboard.PageBuilder` page. Host apps mount it via
  `additional_pages: [atlas: ExAtlas.LiveDashboard.ComputePage]`. Live
  table with Touch/Stop/Terminate row actions. Auto-refreshing;
  subscribes to `ExAtlas.PubSub` for push updates when available.
- Guarded by `Code.ensure_loaded?(Phoenix.LiveDashboard.PageBuilder)` so
  the module only compiles when LiveDashboard is in the host app's deps.

### Added — HTTP + observability

- Every REST / runtime / GraphQL request goes through `Req` with
  `:retry :transient`, 3 retries by default, and telemetry.
- Telemetry events `[:ex_atlas, <provider>, :request]` with
  `%{status: status}` measurements and `%{api, method, url}` metadata.
- Per-call `Req` overrides via `req_options:`.

### Added — Testing

- `ExAtlas.Test.ProviderConformance` — shared ExUnit suite every provider
  implementation must pass. `use`-macro form accepts `:reset` MFA for
  test isolation.
- Full unit coverage (68 tests, 3 doctests).

### Added — Documentation

- Comprehensive `README.md` with architecture diagram, capability
  matrix, GPU mapping table, error kinds, security considerations,
  FAQ, and roadmap.
- `guides/getting_started.md`, `guides/transient_pods.md`,
  `guides/writing_a_provider.md`, `guides/telemetry.md`,
  `guides/testing.md` — long-form deep-dives surfaced via ex_doc extras.
- Full module-level `@moduledoc` on every public module.
