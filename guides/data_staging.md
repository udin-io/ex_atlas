# Data staging: datasets in, artifacts out

A GPU pod starts empty and its disk goes with it. `s3:` tells the container
where to read its dataset, where to write its results and which key to use.
ExAtlas makes no S3 call. The container does, and this guide says what it
should do.

```elixir
ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  gpu: :rtx_4090,
  image: "ghcr.io/acme/trainer:latest",
  command: ["/atlas_entrypoint.sh", "python", "train.py"],
  s3: %{
    endpoint: "https://t3.storage.dev",
    region: "auto",
    access_key_id: System.fetch_env!("TIGRIS_KEY_ID"),
    secret_access_key: System.fetch_env!("TIGRIS_SECRET"),
    dataset_uri: "s3://acme-data/datasets/abc/",
    artifact_uri: "s3://acme-data/artifacts/run-123/"
  }
)
```

## The container contract

ExAtlas puts these variables in the container's environment. A key you leave
out sets no variable.

| `s3:` key | Variable(s) | Secret |
|---|---|---|
| `endpoint` | `AWS_ENDPOINT_URL_S3` | no |
| `region` | `AWS_REGION`, `AWS_DEFAULT_REGION` | no |
| `access_key_id` | `AWS_ACCESS_KEY_ID` | yes |
| `secret_access_key` | `AWS_SECRET_ACCESS_KEY` | yes |
| `session_token` | `AWS_SESSION_TOKEN` | yes |
| `dataset_uri` | `ATLAS_DATASET_URI` | no |
| `artifact_uri` | `ATLAS_ARTIFACT_URI` | no |
| `dataset_url` | `ATLAS_DATASET_URL` | yes |
| `artifact_url` | `ATLAS_ARTIFACT_URL` | yes |

`s3:` needs at least one of the last four. The two URLs are the
[presigned mode](#presigned-mode-no-storage-key-on-the-pod).

The container does three things, in this order:

1. **Before the trainer starts:** copy everything under `ATLAS_DATASET_URI`
   to local disk. If the copy fails, stop with a non-zero exit code.
2. **While it runs:** read the dataset from local disk and write results to a
   local directory.
3. **When it ends, by success, failure or signal:** copy that directory, and
   the log, under `ATLAS_ARTIFACT_URI`. Exit with the trainer's exit code, so
   a failed upload does not turn a good run into a failed task.

Any S3 client that reads the standard `AWS_*` variables works. An image that
already does so needs no script.

## The reference entrypoint

[`guides/scripts/atlas_entrypoint.sh`](https://github.com/udin-io/ex_atlas/blob/main/guides/scripts/atlas_entrypoint.sh)
implements the three steps in POSIX `sh` with `aws-cli`. The Hex package
ships it next to this guide. No ExAtlas code calls it. Its test suite
(`test/guides/atlas_entrypoint_test.exs`) runs it with a stub `aws`.

Copy it into your image, make it executable, and pass your trainer as the
arguments:

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir awscli
COPY atlas_entrypoint.sh /atlas_entrypoint.sh
RUN chmod +x /atlas_entrypoint.sh
COPY train.py /train.py
```

```elixir
command: ["/atlas_entrypoint.sh", "python", "/train.py"]
```

What it does:

| Step | Command |
|---|---|
| Pull | `aws s3 sync "$ATLAS_DATASET_URI" "$ATLAS_DATASET_DIR"`, only when `ATLAS_DATASET_URI` is set. A failure exits with aws's code and runs no trainer. |
| Run | Your arguments, with stdout and stderr merged and copied to `ATLAS_LOG_FILE`. |
| Push | `aws s3 sync "$ATLAS_ARTIFACT_DIR" "$ATLAS_ARTIFACT_URI"` and `aws s3 cp "$ATLAS_LOG_FILE" "${ATLAS_ARTIFACT_URI}atlas.log"`, only when `ATLAS_ARTIFACT_URI` is set. Runs on exit, `INT` and `TERM`. |

With `ATLAS_DATASET_URL` or `ATLAS_ARTIFACT_URL` instead, pull and push use
`curl`; see [presigned mode](#presigned-mode-no-storage-key-on-the-pod).

It forwards `INT` and `TERM` to the trainer, waits for it, uploads, and exits
with the trainer's code (143 for a trainer ended by `TERM`). A failed pull
still uploads the log, which holds aws's error. A failed upload prints
`artifact upload failed` on stderr and changes no exit code.

When `AWS_ENDPOINT_URL_S3` is set, every `aws` call also gets
`--endpoint-url "$AWS_ENDPOINT_URL_S3"`, so an aws-cli release without
service-specific endpoint variables still reaches your store.

It never prints a credential and never runs with `set -x`. Your trainer's own
output goes to the log, so do not print `AWS_SECRET_ACCESS_KEY` from it.

| Variable | Default | Meaning |
|---|---|---|
| `ATLAS_DATASET_DIR` | `/data` | Where the dataset lands |
| `ATLAS_ARTIFACT_DIR` | `/artifacts` | Where the trainer writes results; the script creates it |
| `ATLAS_LOG_FILE` | `/tmp/atlas.log` | The copy of the trainer's output |

The script needs `sh`, `tee`, `mkfifo` and `mktemp`, plus `aws` for the URIs
or `curl`, `tar` and `gzip` for the URLs. Debian, Alpine
(busybox) and Ubuntu images have the last three.

Limits:

- The trainer's stdin is `/dev/null`.
- The script waits for the log copy to finish, and that waits for every
  process that holds the trainer's stdout open. A trainer that leaves a
  background process running delays the upload until that process exits.
- `sync` only adds and overwrites. It never deletes objects under the prefix.

The script never deletes the pod. When it exits, the wrapper that
`run_task/1` puts around `command` reports the exit code and deletes the pod.
See [Transient pods](transient_pods.md#batch-work-run_task1).

## Stores

`s3:` takes any store that speaks the S3 API.

| Store | `endpoint` | `region` |
|---|---|---|
| Tigris | `https://t3.storage.dev` | `auto` |
| Cloudflare R2 | `https://<account_id>.r2.cloudflarestorage.com` | `auto` |
| MinIO | your server, such as `http://minio.internal:9000` | `us-east-1` unless you set another |
| AWS S3 | leave out | the bucket's region, such as `eu-west-1` |

URIs are `s3://bucket/prefix/` whatever the store.

### A store answers HTTP 400 on upload

aws-cli 2.23 and later, and boto3 1.36 and later, send a CRC checksum with
every upload and check one on every download
([AWS SDKs and Tools: data integrity protections](https://docs.aws.amazon.com/sdkref/latest/guide/feature-dataintegrity.html)).
A store that does not support the checksum can refuse the request with HTTP
400. Tell the client to compute checksums only when the operation requires
them:

```elixir
env: %{
  "AWS_REQUEST_CHECKSUM_CALCULATION" => "when_required",
  "AWS_RESPONSE_CHECKSUM_VALIDATION" => "when_required"
}
```

Pass it as `env:` next to `s3:`. Try it when the 400 appears. ExAtlas does
not set it for you.

## What ends a run before the upload

The upload runs only when the script gets to run. These endings give it no
chance, and the pod is deleted with whatever was on its disk:

- `max_runtime_ms` and `max_cost`: the orchestrator deletes the pod.
- `SIGKILL`.
- The out-of-memory killer.

A long trainer should write checkpoints straight to `ATLAS_ARTIFACT_URI` as
it goes, for example with `aws s3 cp` after each epoch, instead of waiting
for the final sync.

## Credentials

The keys sit in the pod's environment. Anyone with your RunPod account's API
key can read them in the RunPod console and API. ExAtlas keeps them out of
`inspect/1` output, logs, crash reports and stored records, but cannot hide
them from the provider.

- Use a key that can reach one bucket, and one prefix where the store allows
  it (AWS IAM policies do).
- Give it read on the dataset prefix and write on the artifact prefix only.
- Rotate it on a schedule. A key passed to a task lives as long as the pod.

Presigned mode, below, puts no storage key on the pod at all.

### Surviving a deploy: `persist: true`

A task with `s3:` and `persist: true` writes a tracking record with the
non-secret part of `s3:` only:

```elixir
# the record's opts
s3: %{
  endpoint: "https://t3.storage.dev",
  region: "auto",
  dataset_uri: "s3://bucket/datasets/abc/",
  artifact_uri: "s3://bucket/artifacts/run-123/",
  credentials: :not_stored
}
```

The keys, the session token and the presigned URLs stay in memory. After a
restart the next boot adopts the pod, which keeps running with the
environment it was rented with. A respawn needs the credentials, and the new
node has none of its own. Name a resolver that hands them back:

```elixir
defmodule MyApp.Atlas do
  # info: %{id:, name:, user_id:, provider:, s3: stored_s3, env_names: [...]}
  def credentials(:trainer, info) do
    {:ok,
     s3: MyApp.Storage.task_credentials(info.user_id) |> Map.merge(info.s3),
     env: %{"HF_TOKEN" => MyApp.Secrets.hf_token()}}
  end
end

ExAtlas.Orchestrator.run_task(
  # ...
  s3: s3,
  env: %{"HF_TOKEN" => token},
  persist: true,
  on_failure: {:respawn, 2},
  respawn_credentials: {MyApp.Atlas, :credentials, [:trainer]}
)
```

- Before any restart, a preempted task respawns with its own `s3:` and
  `env:`. ExAtlas does not call the resolver.
- After adoption, a preemption calls `MyApp.Atlas.credentials(:trainer,
  info)`. `info.s3` is the stored part of `s3:`, without the marker, and
  `info.env_names` lists the names the record kept. The resolver returns
  `{:ok, keyword}` with `:s3`, `:env` or both. `s3:` must come back whole;
  `env:` must hold every name in `env_names` and may add more.
- The record keeps the tuple, never what it returns, so the next restart
  calls it again. The args are stored as given: put no secret in them.
- `config :ex_atlas, :orchestrator, respawn_credentials: {m, f, args}`
  serves records with no tuple, such as those written before the option
  existed.
- Any other return, a raise, a throw, an exit, or no answer within
  `respawn_credentials_timeout_ms` (default 30,000) broadcasts
  `{:respawn_failed, {reason, %ExAtlas.Error{kind: :validation}}}` and ends
  the task. No pod is rented. The message names the resolver and what was
  wrong, never a value it returned or raised.
- With no resolver the respawn fails the same way.

`scrub_keys: [:s3]` keeps the marker alone, so a respawn still needs the
resolver. `Spec.Staging.new/1` refuses `credentials: :not_stored`, so a
record's `s3:` cannot rent a pod by hand either. A host `TrackingStore` must
keep `opts` whole, the resolver tuple included; one that drops the `s3:`
marker still needs the resolver, since an adopted `s3:` is never trusted to
hold credentials.

## Presigned mode: no storage key on the pod

You presign two URLs on your side: a GET for one dataset archive and a PUT
for one artifact archive. The pod gets only those. It can read one object and
write one object, until the URLs expire. ExAtlas never presigns and never
reads a URL's expiry. `ex_aws_s3` presigns locally, with no request to S3:

```elixir
config = ExAws.Config.new(:s3)

{:ok, dataset_url} =
  ExAws.S3.presigned_url(config, :get, "acme-data", "datasets/abc.tar.gz", expires_in: 3_600)

# Longer than max_runtime_ms: the PUT runs when the trainer ends.
{:ok, artifact_url} =
  ExAws.S3.presigned_url(config, :put, "acme-data", "artifacts/run-123.tar.gz",
    expires_in: 6 * 3_600
  )

ExAtlas.Orchestrator.run_task(
  provider: :runpod,
  gpu: :rtx_4090,
  image: "ghcr.io/acme/trainer:latest",
  command: ["/atlas_entrypoint.sh", "python", "/train.py"],
  max_runtime_ms: :timer.hours(4),
  s3: %{dataset_url: dataset_url, artifact_url: artifact_url}
)
# container env: ATLAS_DATASET_URL and ATLAS_ARTIFACT_URL, no AWS_* key
```

Each URL must be `http://` or `https://` with a host and a path to the
object, carry no user info, and hold only RFC 3986 characters after the host,
with no braces or brackets. `ExAws.S3.presigned_url/5` output passes. A URL is
a bearer credential until it expires, so ExAtlas treats it like a key:
`inspect/1`, errors, crash reports and tracking records never show it. Plain
`http://` sends that credential in clear text; use it only for a store on a
network you trust, such as a local MinIO.

The reference entrypoint:

| Step | Command |
|---|---|
| Pull | `curl -fsS -o <file> "$ATLAS_DATASET_URL"`, then `tar -xf <file> -C "$ATLAS_DATASET_DIR"`. The archive may be a plain tar or compressed with gzip, bzip2 or xz. The file sits in `ATLAS_DATASET_DIR` until it is unpacked, so that disk needs room for both. A failure exits with curl's or tar's code and runs no trainer. |
| Push | Copies the log to `$ATLAS_ARTIFACT_DIR/atlas.log`, replacing a trainer file of that name, packs the directory with `tar -czf` into a file under `$TMPDIR`, then `curl -fsS -T <file> "$ATLAS_ARTIFACT_URL"`. One object holds the artifacts and the log. Keep `TMPDIR` outside `ATLAS_ARTIFACT_DIR`, or tar tries to pack its own output. |

Every `curl` call also gets `-q` (ignore a `.curlrc` in the image), `-g` (no
URL globbing), `--connect-timeout 30` and `--speed-limit 1024 --speed-time
120`, which end a transfer that stalls for two minutes instead of holding the
pod until `max_runtime_ms`. Redirects are not followed.

- **A URI and a URL for the same side:** the URI wins, and the script prints
  `ATLAS_DATASET_URL ignored: ATLAS_DATASET_URI is set` (or the artifact
  equivalent). The two modes mix across sides: a URI for the dataset and a
  URL for the artifacts works.
- **Expiry.** A SigV4 presigned URL lives at most 7 days, and no longer than
  the credentials that signed it: a URL signed with a session token dies with
  the token. Presign the PUT for longer than `max_runtime_ms`.
- **Size.** A single PUT holds at most 5 GB. Multipart presigned uploads are
  not supported.
- **One file that tar cannot read** is reported (`tar exit N while packing the
  artifacts`), and whatever tar packed still uploads. GNU tar skips the file;
  bsdtar stops there.
- **What prints.** The script never prints a URL. `curl -f` prints no
  response body on an HTTP error, and S3's error body for a bad signature
  echoes the signature. curl's own error lines name the host at most, such as
  `Could not resolve host`.
- **What the trainer sees.** The script moves both URLs out of the
  environment before the trainer starts, so a trainer or library that dumps
  its environment prints neither. They are still on curl's command line while
  it runs, and in the script's own `/proc/<pid>/environ`, which a process
  running as the same user can read. The pod's environment in the RunPod
  console and API holds them too.
