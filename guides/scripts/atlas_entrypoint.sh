#!/bin/sh
# Reference entrypoint for an ExAtlas task container. See guides/data_staging.md.
#
#   atlas_entrypoint.sh TRAINER [ARGS...]
#
# 1. Pulls ATLAS_DATASET_URI into ATLAS_DATASET_DIR (default /data), or
#    downloads the tar archive at the presigned ATLAS_DATASET_URL and unpacks
#    it there. The URI wins when both are set.
# 2. Runs the trainer, copying stdout and stderr to ATLAS_LOG_FILE
#    (default /tmp/atlas.log).
# 3. On exit, INT or TERM, syncs ATLAS_ARTIFACT_DIR (default /artifacts) and
#    the log to ATLAS_ARTIFACT_URI.
#
# The exit code is the trainer's. A failed upload is printed and changes
# nothing. The script never deletes the pod: the wrapper that ExAtlas puts
# around the command does that after this script exits.
#
# Credentials come from the environment (AWS_ACCESS_KEY_ID and friends, or the
# presigned URLs, which grant access to whoever holds them). The script never
# prints them and never runs with `set -x`.

DATASET_DIR=${ATLAS_DATASET_DIR:-/data}
ARTIFACT_DIR=${ATLAS_ARTIFACT_DIR:-/artifacts}
LOG=${ATLAS_LOG_FILE:-/tmp/atlas.log}

say() { printf 'atlas_entrypoint: %s\n' "$*" >&2; }

if [ "$#" -eq 0 ]; then
  say "usage: atlas_entrypoint.sh TRAINER [ARGS...]"
  exit 2
fi

# `--endpoint-url` as well as AWS_ENDPOINT_URL_S3: aws-cli releases without
# service-specific endpoint variables ignore the variable.
s3() {
  if [ -n "${AWS_ENDPOINT_URL_S3:-}" ]; then
    aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3 "$@"
  else
    aws s3 "$@"
  fi
}

work=$(mktemp -d) || exit 1
mkdir -p "$ARTIFACT_DIR"
trainer_pid=
: > "$LOG"

upload() {
  [ -n "${ATLAS_ARTIFACT_URI:-}" ] || return 0
  uri=${ATLAS_ARTIFACT_URI%/}

  s3 sync "$ARTIFACT_DIR" "$uri/" || say "artifact upload failed (aws exit $?)"
  s3 cp "$LOG" "$uri/atlas.log" || say "artifact upload failed: atlas.log (aws exit $?)"
}

finish() {
  code=$?
  trap - EXIT INT TERM
  upload
  rm -rf "$work"
  exit "$code"
}

# A signal goes to the trainer; the script then ends the normal way, with the
# trainer's status. Before the trainer starts, it ends the script at once.
on_signal() {
  if [ -n "$trainer_pid" ]; then
    kill -TERM "$trainer_pid" 2>/dev/null
  else
    exit 143
  fi
}

trap finish EXIT
trap on_signal INT TERM

# `curl -f` prints no response body on an HTTP error. S3's error body for a
# bad signature echoes the signature it was given.
download() {
  archive="$DATASET_DIR/.atlas_dataset_download"
  tool=curl
  curl -fsSL -o "$archive" "$ATLAS_DATASET_URL" || { rc=$?; rm -f "$archive"; return "$rc"; }
  # A file, not a pipe: tar detects gzip, bzip2 or xz only in a file it can
  # read twice, and a pipe would hide curl's exit code.
  tool=tar
  tar -xf "$archive" -C "$DATASET_DIR"
  rc=$?
  rm -f "$archive"
  return "$rc"
}

pull=
if [ -n "${ATLAS_DATASET_URI:-}" ]; then
  [ -n "${ATLAS_DATASET_URL:-}" ] && say "ATLAS_DATASET_URL ignored: ATLAS_DATASET_URI is set"
  pull=aws
elif [ -n "${ATLAS_DATASET_URL:-}" ]; then
  pull=curl
fi

if [ -n "$pull" ]; then
  mkdir -p "$DATASET_DIR"
  if [ "$pull" = aws ]; then
    tool=aws
    s3 sync "$ATLAS_DATASET_URI" "$DATASET_DIR" > "$work/pull" 2>&1
  else
    download > "$work/pull" 2>&1
  fi
  rc=$?
  cat "$work/pull"
  cat "$work/pull" >> "$LOG"
  if [ "$rc" -ne 0 ]; then
    say "dataset pull failed ($tool exit $rc); the trainer did not run"
    exit "$rc"
  fi
fi

# A fifo and `wait` give the trainer's own status; `trainer | tee` would
# report tee's, and POSIX sh has no pipefail.
mkfifo "$work/out" || exit 1
tee -a "$LOG" < "$work/out" &
tee_pid=$!
"$@" > "$work/out" 2>&1 &
trainer_pid=$!

# A trapped signal interrupts `wait`, so loop until the trainer is gone.
while :; do
  wait "$trainer_pid"
  code=$?
  kill -0 "$trainer_pid" 2>/dev/null || break
done
wait "$tee_pid"

exit "$code"
