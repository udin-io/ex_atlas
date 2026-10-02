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

The script needs `sh`, `aws`, `tee`, `mkfifo` and `mktemp`. Debian, Alpine
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

A later slice (#73) adds presigned URLs, which put no storage key on the pod.
