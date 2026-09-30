#!/usr/bin/env bash
# Live probe for issue 34: four Runpod REST v2 facts the OpenAPI spec does not
# state. It rents the cheapest GPU with stock for a few minutes and answers:
#
#   Q1  Can the pod-scoped RUNPOD_API_KEY inside a container
#       DELETE https://api.runpod.io/v2/pods/$RUNPOD_POD_ID?
#   Q2  After a DELETE, does GET /v2/pods/{id} answer 404 or 200 TERMINATED?
#   Q3  When the container command exits, does the pod read EXITED or RUNNING?
#   Q4  Does GET /v2/pods/{id} resolve the id of a pod created through v1?
#
# It deletes every pod it created, on success, error, Ctrl-C, TERM and HUP,
# and its last lines name each pod id and whether it is gone.
#
# Usage, from the repository root:
#   scripts/probe_runpod_v2.sh
# It prompts for the key and does not echo it. With RUNPOD_API_KEY already in
# the environment it uses that instead; `ps -E` can then show the key on this
# script's own process, which the prompt avoids.
#
# Optional environment:
#   PROBE_GPU_ID     GPU type id to rent (default: cheapest with stock)
#   PROBE_CLOUD      COMMUNITY (default) or SECURE
#   PROBE_TIMEOUT    seconds to wait for a pod to start (default 900)
#   PROBE_EXIT_WATCH seconds to watch the exiting pod (default 180)
#   PROBE_ONLY       q3: rent only the exiting pod and answer only Q3
#
# Needs bash 3.2+, curl and jq. The key never appears on a command line, in a
# URL, in output or in a file: curl reads the Authorization header from stdin,
# and the key leaves the environment before any child process starts.

# The xtrace check comes first: `bash -x` would print the key.
case $- in
  *x*) echo "refusing to run under xtrace: it would print the API key" >&2; exit 2 ;;
esac

set -euo pipefail
ulimit -c 0

V2=https://api.runpod.io/v2
V1=https://rest.runpod.io/v1
# curl -q must come first: it skips ~/.curlrc, which could trace or proxy the
# Authorization header.
CURL_SAFETY=(-q --proto =https)
# Test hook: point both APIs at a local fake. Only loopback is accepted, so the
# key can never be sent anywhere but Runpod or this machine.
if [[ -n ${PROBE_API_BASE:-} ]]; then
  if [[ ! $PROBE_API_BASE =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "PROBE_API_BASE must be http://127.0.0.1:<port> or http://localhost:<port>" >&2
    exit 2
  fi
  V2=$PROBE_API_BASE/v2
  V1=$PROBE_API_BASE/v1
  CURL_SAFETY=(-q --proto =http --noproxy '*')
fi

IMAGE=curlimages/curl:8.10.1
CLOUD=${PROBE_CLOUD:-COMMUNITY}
TIMEOUT=${PROBE_TIMEOUT:-900}
EXIT_WATCH=${PROBE_EXIT_WATCH:-180}
POLL=${PROBE_POLL:-10}
ONLY=${PROBE_ONLY:-}
TAG="ex-atlas-probe-$(date +%s)-$RANDOM"

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }
done

for n in "$TIMEOUT" "$EXIT_WATCH" "$POLL"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo "PROBE_TIMEOUT, PROBE_EXIT_WATCH and PROBE_POLL take whole seconds" >&2; exit 2; }
done
((POLL >= 1)) || { echo "PROBE_POLL must be at least 1" >&2; exit 2; }

case $ONLY in "" | q3) ;; *) echo "PROBE_ONLY must be empty or q3" >&2; exit 2 ;; esac

case $CLOUD in SECURE | COMMUNITY) ;; *) echo "PROBE_CLOUD must be SECURE or COMMUNITY" >&2; exit 2 ;; esac

# The key lives in an unexported variable, so no child process inherits it.
unset _PROBE_KEY
if [[ -n ${RUNPOD_API_KEY:-} ]]; then
  _PROBE_KEY=$RUNPOD_API_KEY
  unset RUNPOD_API_KEY
elif [[ -t 0 ]]; then
  read -rsp "Runpod API key (not echoed): " _PROBE_KEY
  echo >&2
else
  echo "no key: run from a terminal to be prompted, or set RUNPOD_API_KEY" >&2
  exit 2
fi
declare +x _PROBE_KEY

# The key goes into a curl config line; a quote or backslash would break it.
if [[ ! $_PROBE_KEY =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "the key has characters outside [A-Za-z0-9_.-]; refusing to use it" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ex_atlas_probe.XXXXXX")
RESP=$WORK/resp.json

CREATED_IDS=()
CREATED_ROLES=()
# Set when a create may have made a pod whose id we never saw.
UNSEEN_CREATE=0
# Nothing to sweep for before the first create.
CREATE_SENT=0

A1="not answered"
A2="not answered"
A3="not answered"
A4="not answered"
EXTRA=()

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Final output: stdout, or stderr once stdout is a closed pipe (a `| tee` that
# Ctrl-C killed), so the cleanup lines always reach the terminal. `cat` does
# the stdout write: it reports a failed write, and keeps it out of bash's own
# stdout buffer, which would otherwise print the line twice.
OUT_BROKEN=0
out() {
  if [[ $OUT_BROKEN == 0 ]] && printf '%s\n' "$*" | cat 2>/dev/null; then return; fi
  OUT_BROKEN=1
  printf '%s\n' "$*" >&2
}

# api METHOD URL [BODY_FILE] -> prints the HTTP status, body lands in $RESP.
# The Authorization header comes from stdin (curl --config -), so the key never
# reaches argv, where `ps` would show it.
api() {
  local method=$1 url=$2 body=${3:-}
  local args=("${CURL_SAFETY[@]}" --config - -sS -m 30 -o "$RESP" -w '%{http_code}'
    -X "$method" -H 'Accept: application/json')
  if [[ -n $body ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  : >"$RESP"
  printf 'header = "Authorization: Bearer %s"\n' "$_PROBE_KEY" | curl "${args[@]}" "$url" 2>/dev/null || true
}

# The error's own words, never the whole body, with control characters removed.
problem() {
  jq -r '[.title, .detail, .message, (.errors // [] | if type == "array" then map(tostring) | join("; ") else tostring end)]
         | map(select(. != null and . != "")) | join(": ")' "$RESP" 2>/dev/null |
    tr -d '\000-\037\177' | head -c 300 || true
}

field() { jq -r "$1 // empty" "$RESP" 2>/dev/null | tr -d '\000-\037\177' || true; }

valid_id() { [[ $1 =~ ^[A-Za-z0-9_-]+$ ]]; }

track() {
  local id=$1 role=$2 i
  if ! valid_id "$id"; then
    log "a $role create answered 201 without a usable pod id; the name sweep will look for it"
    UNSEEN_CREATE=1
    return
  fi
  for i in ${CREATED_IDS[@]+"${CREATED_IDS[@]}"}; do [[ $i == "$id" ]] && return; done
  CREATED_IDS+=("$id")
  CREATED_ROLES+=("$role")
  log "created pod $id ($role)"
}

# pod_state ID -> "404", "200 STATUS" or "<code> error"
pod_state() {
  local code
  code=$(api GET "$V2/pods/$1")
  case $code in
    200) echo "200 $(field .status)" ;;
    404) echo "404" ;;
    *) echo "$code error" ;;
  esac
}

# Container log lines, read for at most 15 s from the SSE stream.
pod_logs() {
  local file=$WORK/logs.txt
  printf 'header = "Authorization: Bearer %s"\n' "$_PROBE_KEY" |
    curl "${CURL_SAFETY[@]}" --config - -sS -N -m 15 -H 'Accept: text/event-stream' \
      "$V2/pods/$1/logs?source=container&tail=500" 2>/dev/null | head -c 200000 >"$file" || true
  sed -n 's/^data: *//p' "$file" | jq -r '.line // empty' 2>/dev/null || true
}

# pod_gone ID -> "gone", "exists" or "unknown (...)". Gone means gone on v2
# and on v1: a v1 pod that v2 cannot see reads 404 on v2 while it still bills.
pod_gone() {
  local s code
  s=$(pod_state "$1")
  case $s in
    404 | "200 TERMINATED") ;;
    "200 "*) echo exists; return ;;
    *) echo "unknown (v2 answered $s)"; return ;;
  esac
  code=$(api GET "$V1/pods/$1")
  case $code in
    404) echo gone ;;
    200) if [[ $(field .desiredStatus) == TERMINATED ]]; then echo gone; else echo exists; fi ;;
    *) echo "unknown (v2 says gone, v1 answered $code)" ;;
  esac
}

# delete_pod ID -> "v2:<code>" or "v2:<code> v1:<code>"
delete_pod() {
  local id=$1 v2 v1
  v2=$(api DELETE "$V2/pods/$id")
  if [[ $v2 == 204 || $v2 == 200 ]]; then
    echo "v2:$v2"
    return
  fi
  v1=$(api DELETE "$V1/pods/$id")
  echo "v2:$v2 v1:$v1"
}

# sweep -> adds every pod named "$TAG*" on v2 or v1 to the tracked list, and
# appends to SWEEP_PROBLEMS each place it could not look. It runs in the main
# shell, never in $(...), so `track` updates the list cleanup reads.
SWEEP_PROBLEMS=""
sweep() {
  local cursor="" seen_cursors=" " page code id name problems=""
  for ((page = 0; page < 20; page++)); do
    code=$(api GET "$V2/pods?limit=1000${cursor:+&cursor=$cursor}")
    if [[ $code != 200 ]]; then
      problems="$problems v2 list answered HTTP $code;"
      break
    fi
    while IFS=$'\t' read -r id name; do
      [[ $name == "$TAG"* ]] && track "$id" "found by name"
    done < <(jq -r '.pods[]? | [.id, .name] | @tsv' "$RESP" 2>/dev/null)
    cursor=$(jq -r 'if .pagination.hasNextPage then .pagination.nextCursor // empty | @uri else empty end' "$RESP" 2>/dev/null)
    [[ -z $cursor ]] && break
    if [[ $seen_cursors == *" $cursor "* ]]; then
      problems="$problems v2 list cursor repeated;"
      break
    fi
    seen_cursors="$seen_cursors$cursor "
  done
  ((page < 20)) || problems="$problems v2 list passed 20 pages;"

  code=$(api GET "$V1/pods")
  if [[ $code == 200 ]]; then
    while IFS=$'\t' read -r id name; do
      [[ $name == "$TAG"* ]] && track "$id" "found by name on v1"
    done < <(jq -r '(if type == "array" then . else .pods // [] end)[]? | [.id, .name] | @tsv' "$RESP" 2>/dev/null)
  else
    problems="$problems v1 list answered HTTP $code;"
  fi
  SWEEP_PROBLEMS="$SWEEP_PROBLEMS$problems"
}

print_answers() {
  out ""
  out "== Runpod v2 probe answers ($TAG) =="
  out "Q1 pod-scoped key can DELETE /v2/pods/\$RUNPOD_POD_ID from inside the pod: $A1"
  out "Q2 a deleted pod reads: $A2"
  out "Q3 a pod whose command exited reads: $A3"
  out "Q4 a v1-created pod id resolves on v2: $A4"
  local line
  for line in ${EXTRA[@]+"${EXTRA[@]}"}; do out "   $line"; done
}

# delete_all -> deletes every tracked pod, then prints one line per pod.
delete_all() {
  local n=${#CREATED_IDS[@]} k attempt
  for ((k = 0; k < n; k++)); do
    for attempt in 1 2 3; do
      [[ $(pod_gone "${CREATED_IDS[$k]}") == gone ]] && break
      delete_pod "${CREATED_IDS[$k]}" >/dev/null
      sleep 3
    done
  done
}

# The EXIT trap ignores signals before anything else runs: cleanup is what
# stops the billing, and nothing may cut it short, not a second Ctrl-C, a
# closed terminal, or a `| tee` that died first.
cleanup() {
  local rc=$1
  trap - EXIT
  set +e

  local id k state left=0
  if [[ $CREATE_SENT == 1 ]]; then
    sweep
    delete_all
    # A pod whose create was cut off can take a few seconds to be listed.
    sleep 10
    sweep
    delete_all
  fi

  print_answers
  out ""
  out "== Cleanup =="
  if [[ ${#CREATED_IDS[@]} == 0 ]]; then
    out "no pods were created"
  fi
  for ((k = 0; k < ${#CREATED_IDS[@]}; k++)); do
    id=${CREATED_IDS[$k]}
    state=$(pod_gone "$id")
    if [[ $state == gone ]]; then
      out "pod $id (${CREATED_ROLES[$k]}): gone"
    else
      out "pod $id (${CREATED_ROLES[$k]}): STILL EXISTS or UNKNOWN ($state) - delete it at https://console.runpod.io/pods"
      left=1
    fi
  done
  if [[ -n $SWEEP_PROBLEMS ]]; then
    out "sweep incomplete:$SWEEP_PROBLEMS check https://console.runpod.io/pods for names starting with $TAG"
    left=1
  fi
  if [[ $UNSEEN_CREATE == 1 ]]; then
    out "a create was cut off or answered without an id; the sweeps looked for its pod by name."
    out "check https://console.runpod.io/pods for names starting with $TAG to be sure"
    left=1
  fi
  rm -rf "$WORK"
  [[ $left == 0 ]] || rc=1
  exit "$rc"
}
trap 'rc=$?; trap "" PIPE INT TERM HUP; cleanup "$rc"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Hold signals across a create and its `track`, so a pod the API made is always
# recorded; then act on any signal that arrived. Ctrl-C still reaches curl, so a
# cut-off create is left to the name sweep.
PENDING=""
hold_signals() {
  PENDING=""
  trap 'PENDING=130' INT
  trap 'PENDING=143' TERM
  trap 'PENDING=129' HUP
}
release_signals() {
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  [[ -z $PENDING ]] || exit "$PENDING"
}

# --- preflight --------------------------------------------------------------

code=$(api GET "$V2/pods?limit=1")
case $code in
  200) ;;
  401 | 403) echo "Runpod refused the key (HTTP $code): $(problem)" >&2; exit 1 ;;
  *) echo "GET /v2/pods answered HTTP $code: $(problem)" >&2; exit 1 ;;
esac

# GPUS[i] is a GPU type id; GPU_DCS[i] is the comma-separated data centers where
# the catalog lists it in stock (empty: let Runpod choose).
GPUS=()
GPU_DCS=()
if [[ -n ${PROBE_GPU_ID:-} ]]; then
  GPUS=("$PROBE_GPU_ID")
  GPU_DCS=("")
else
  code=$(api GET "$V2/catalog/gpus?include=AVAILABILITY&product=POD&cloud=$CLOUD")
  [[ $code == 200 ]] || { echo "GPU catalog answered HTTP $code: $(problem)" >&2; exit 1; }
  lower=$(printf '%s' "$CLOUD" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r g dcs; do GPUS+=("$g"); GPU_DCS+=("$dcs"); done < <(
    jq -r --arg c "$lower" '
      .gpus
      | map(select(.[$c] == true and (.availability // "NONE") != "NONE" and (.price[$c] // 0) > 0))
      | sort_by(.price[$c]) | .[0:4][]
      | [.id, ([.dataCenters[]? | select((.availability // "NONE") != "NONE") | .id] | join(","))] | @tsv' "$RESP"
  )
  [[ ${#GPUS[@]} -gt 0 ]] || { echo "no $CLOUD GPU has stock right now; set PROBE_GPU_ID" >&2; exit 1; }
fi
for ((i = 0; i < ${#GPUS[@]}; i++)); do
  log "GPU candidate $((i + 1)): ${GPUS[$i]} (in stock in: ${GPU_DCS[$i]:-any data center})"
done

# create ROLE URL BODY_FILE -> 0 and POD_ID set when the pod was made.
create() {
  local role=$1 url=$2 body=$3 code
  hold_signals
  CREATE_SENT=1
  code=$(api POST "$url" "$body")
  POD_ID=""
  case $code in
    200 | 201) POD_ID=$(field .id); track "$POD_ID" "$role" ;;
    # Cut off, timed out or a gateway error: Runpod may have made it anyway.
    000 | "" | 5*) UNSEEN_CREATE=1 ;;
  esac
  release_signals
  if [[ -n $POD_ID ]] && valid_id "$POD_ID"; then return 0; fi
  log "$role create answered HTTP $code: $(problem)"
  return 1
}

# create_v2 ROLE SCRIPT [DISK_GB] -> sets POD_ID and returns 0, or returns 1 with
# CREATE_FAIL naming the last refusal. No DISK_GB leaves `disk` to Runpod's
# default. Each candidate GPU gets a body built from scratch.
create_v2() {
  local role=$1 script=$2 disk=${3:-} gpu body=$WORK/body.json k
  for ((k = 0; k < ${#GPUS[@]}; k++)); do
    gpu=${GPUS[$k]}
    # dataCenterIds: the data centers the catalog lists this GPU in. Omitted
    # when unknown, which lets the scheduler choose.
    jq -n --arg name "$TAG-$role" --arg image "$IMAGE" --arg gpu "$gpu" --arg cloud "$CLOUD" \
      --arg script "$script" --arg disk "$disk" --arg dcs "${GPU_DCS[$k]}" '{
        name: $name, image: $image, cloud: $cloud,
        gpu: {id: $gpu, count: 1},
        entrypoint: ["/bin/sh", "-c"],
        cmd: [$script]
      } + (if $disk == "" then {} else {disk: ($disk | tonumber)} end)
        + (if $dcs == "" then {} else {dataCenterIds: ($dcs | split(","))} end)' >"$body"
    create "$role" "$V2/pods" "$body" && return 0
    CREATE_FAIL="$(problem)"
    log "$role body sent for $gpu: $(jq -c 'keys' "$body") ($(wc -c <"$body" | tr -d ' ') bytes)"
  done
  CREATE_FAIL="no candidate GPU accepted it; last answer: ${CREATE_FAIL:-none}"
  log "could not create the $role pod: $CREATE_FAIL"
  return 1
}

# wait_started ID -> echoes the first state past PROVISIONING and STARTING:
# "200 RUNNING", "200 EXITED", "200 ERROR", "200 TERMINATED", "404", or
# "timeout, last state ...". Returns 1 on timeout.
wait_started() {
  local id=$1 waited=0 s=""
  while ((waited < TIMEOUT)); do
    s=$(pod_state "$id")
    case $s in
      "200 PROVISIONING" | "200 STARTING" | *error) ;;
      *) echo "$s"; return 0 ;;
    esac
    sleep "$POLL"
    waited=$((waited + POLL))
  done
  echo "timeout, last state $s"
  return 1
}

# --- Q4: a v1 pod read through v2 --------------------------------------------

# Disk and volume are left out, as ex_atlas 0.5 leaves them out when the caller
# does not set them, so the extra lines show what v1 gave such a pod.
if [[ -n $ONLY ]]; then
  A4="NOT RUN (PROBE_ONLY=$ONLY)"
else
log "Q4: creating a pod through v1"
v1_body=$WORK/v1.json
V1_ID=""
# v1 takes every candidate in one create and places the pod on whichever is
# free (gpuTypePriority defaults to "availability"). Its dataCenterIds default to
# a fixed list, so the catalog's in-stock data centers go in when known.
v1_gpus=$(printf '%s\n' "${GPUS[@]}" | jq -R . | jq -sc .)
v1_dcs=$(printf '%s\n' "${GPU_DCS[@]}" | tr ',' '\n' | jq -R 'select(. != "")' | jq -sc 'unique')
jq -n --arg name "$TAG-v1" --arg image "$IMAGE" --arg cloud "$CLOUD" \
  --argjson gpus "$v1_gpus" --argjson dcs "$v1_dcs" '{
    name: $name, imageName: $image, computeType: "GPU", cloudType: $cloud,
    gpuTypeIds: $gpus, gpuCount: 1,
    dockerEntrypoint: ["/bin/sh", "-c"], dockerStartCmd: ["sleep 600"]
  } + (if ($dcs | length) == 0 then {} else {dataCenterIds: $dcs} end)' >"$v1_body"
log "Q4 v1 body sent: $(jq -c . "$v1_body")"
if create "created via v1" "$V1/pods" "$v1_body"; then
  V1_ID=$POD_ID
fi

if [[ -n $V1_ID ]]; then
  s=$(pod_state "$V1_ID")
  case $s in
    "200 "*)
      A4="YES (GET /v2/pods/<v1 id> answered 200, status ${s#200 })"
      EXTRA+=("v1 defaults read on v2: disk=$(field .disk) mounts=$(jq -c '.mounts' "$RESP" 2>/dev/null)")
      ;;
    404) A4="NO (GET /v2/pods/<v1 id> answered 404)" ;;
    *) A4="UNCLEAR (GET /v2/pods/<v1 id> answered $s: $(problem))" ;;
  esac
  if [[ $(api GET "$V1/pods/$V1_ID") == 200 ]]; then
    EXTRA+=("v1 defaults read on v1: $(jq -c '{containerDiskInGb, volumeInGb, volumeMountPath}' "$RESP" 2>/dev/null)")
  fi
  d=$(delete_pod "$V1_ID")
  EXTRA+=("Q4 extra: DELETE of the v1 pod answered $d")
else
  A4="NOT RUN (v1 create failed; see the log above)"
fi
fi

# --- Q1, Q2, Q3: two v2 pods run side by side --------------------------------

# Pod A waits 45 s, so a poll sees it RUNNING, then deletes itself with the
# pod-scoped key, the way ex_atlas's trap does, and logs the HTTP status. It
# then sleeps, so a refused DELETE leaves the pod RUNNING for us to read.
SELF_SCRIPT='echo "probe-key-present=$([ -n "$RUNPOD_API_KEY" ] && echo yes || echo no)"; echo "probe-pod-id-present=$([ -n "$RUNPOD_POD_ID" ] && echo yes || echo no)"; sleep 45; code=$(curl -sS -m 30 -o /tmp/r -w "%{http_code}" -X DELETE -H "Authorization: Bearer $RUNPOD_API_KEY" "https://api.runpod.io/v2/pods/$RUNPOD_POD_ID"); echo "probe-delete-status=$code"; head -c 300 /tmp/r; echo; sleep 600'

# Pod B runs 30 s, so a poll sees it RUNNING, then exits 0 with no trap.
EXIT_SCRIPT='echo probe-started; sleep 30; echo probe-exited; exit 0'

log "Q1-Q3: creating the v2 pods"
# The two pods answer separate questions: a failed create leaves the other
# pod's questions to run.
A_ID=""
B_ID=""
if [[ -n $ONLY ]]; then
  A1="NOT RUN (PROBE_ONLY=$ONLY)"
  A2="NOT RUN (PROBE_ONLY=$ONLY)"
elif create_v2 selfdelete "$SELF_SCRIPT" 5; then
  A_ID=$POD_ID
else
  A1="NOT ANSWERED (selfdelete pod not created: $CREATE_FAIL)"
  A2="NOT ANSWERED (selfdelete pod not created)"
fi
# The exits pod sends the same `disk` as the selfdelete pod. The v2 docs mark
# `disk` optional, but three owner runs refused the one body without it with
# "You must either provide a template id or pod configuration parameters" (22:07
# and the 8d2a3ca8 run, on L40 and RTX 6000 Ada), while the selfdelete body with
# `disk: 5` was accepted on RTX 5000 Ada a second earlier.
if create_v2 exits "$EXIT_SCRIPT" 5; then
  B_ID=$POD_ID
else
  A3="NOT ANSWERED (exits pod not created: $CREATE_FAIL)"
fi

# The field names of a real v2 pod body, for the test fixtures, and what v2
# gives a pod created with no disk and no mounts.
if [[ -n $B_ID && $(api GET "$V2/pods/$B_ID") == 200 ]]; then
  EXTRA+=("v2 pod fields: $(jq -r 'keys | join(",")' "$RESP" 2>/dev/null)")
  EXTRA+=("v2 pod read back: disk=$(field .disk) mounts=$(jq -c '.mounts' "$RESP" 2>/dev/null)")
fi

if [[ -n $B_ID ]]; then
log "Q3: waiting for pod $B_ID to run and exit its command"
if st=$(wait_started "$B_ID"); then
  seen=${st#200 }
  final=$seen
  watched=0
  while [[ $final == RUNNING ]] && ((watched < EXIT_WATCH)); do
    sleep "$POLL"
    watched=$((watched + POLL))
    s=$(pod_state "$B_ID")
    [[ $s == *error ]] && continue
    final=${s#200 }
    [[ $seen == *"$final" ]] || seen="$seen -> $final"
  done
  runs=$(pod_logs "$B_ID" | grep -c '^probe-started' || true)
  case $final in
    EXITED) A3="EXITED (statuses seen: $seen; command started $runs time(s))" ;;
    RUNNING) A3="RUNNING (still RUNNING ${watched} s after it first ran, 30 s of work; command started $runs time(s))" ;;
    *) A3="$final (statuses seen: $seen; command started $runs time(s))" ;;
  esac
else
  A3="NOT ANSWERED (pod $B_ID never started: $st)"
fi
fi

if [[ -n $A_ID ]]; then
log "Q1: waiting for pod $A_ID to delete itself"
deleted_by="the pod itself"
if st=$(wait_started "$A_ID"); then
  if [[ $st == 404 || $st == "200 TERMINATED" ]]; then
    A1="YES (the pod removed itself before a poll saw it RUNNING; first read: $st)"
  else
    waited=0
    status=""
    while ((waited < 180)); do
      s=$(pod_state "$A_ID")
      if [[ $s == 404 || $s == "200 TERMINATED" ]]; then
        A1="YES (the pod removed itself; first read after: $s)"
        break
      fi
      status=$(pod_logs "$A_ID" | sed -n 's/^probe-delete-status=//p' | tail -1)
      if [[ -n $status && $status != 2* ]]; then
        present=$(pod_logs "$A_ID" | sed -n 's/^probe-key-present=//p' | tail -1)
        A1="NO (DELETE from inside the pod answered HTTP $status; RUNPOD_API_KEY present in pod: ${present:-unknown})"
        break
      fi
      sleep "$POLL"
      waited=$((waited + POLL))
    done
    if [[ $A1 == "not answered" ]]; then
      A1="UNCLEAR (no removal and no refusal in the pod log after 180 s; last logged status: ${status:-none})"
    fi
  fi

  # Q2: delete it ourselves when it did not, then read it back for 60 s.
  if [[ $A1 != YES* ]]; then
    d=$(delete_pod "$A_ID")
    deleted_by="this script (DELETE answered $d)"
  fi
  reads=""
  for ((t = 0; t <= 60; t += 10)); do
    s=$(pod_state "$A_ID")
    reads="$reads${reads:+, }${t}s: $s"
    [[ $s == 404 ]] && break
    sleep 10
  done
  first=${reads%%,*}
  if [[ $first == *": 404" ]]; then
    A2="404 (deleted by $deleted_by; reads: $reads)"
  elif [[ $reads == *TERMINATED* && $reads == *": 404" ]]; then
    A2="TERMINATED, then 404 (deleted by $deleted_by; reads: $reads)"
  elif [[ $reads == *TERMINATED* ]]; then
    A2="TERMINATED for 60 s (deleted by $deleted_by; reads: $reads)"
  else
    A2="OTHER (deleted by $deleted_by; reads: $reads)"
  fi
else
  A1="NOT ANSWERED (pod $A_ID never started: $st)"
  A2="NOT ANSWERED (pod $A_ID never started)"
fi
fi

log "done; cleaning up"
