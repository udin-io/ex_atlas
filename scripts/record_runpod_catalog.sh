#!/usr/bin/env bash
# Records Runpod's v2 GPU catalog for issue 40, and compares it with the GraphQL
# answer that ExAtlas.list_gpu_types/1 reads today. It only reads: five GET/POST
# requests that list GPU types, no pod, no volume, no endpoint. It rents nothing
# and changes nothing on your account.
#
# Requests, in order:
#   1. GET  /v2/catalog/gpus?include=AVAILABILITY&product=POD&cloud=SECURE
#   2. GET  /v2/catalog/gpus?include=AVAILABILITY&product=POD&cloud=COMMUNITY
#   3. POST /graphql  the query list_gpu_types/1 sends today, verbatim
#   4. POST /graphql  the same query with stockStatus under lowestPrice, where
#                     Runpod's GraphQL reference puts it (today's query asks
#                     GpuType for it, and the reference lists none there)
# Requests 3 and 4 are skipped with RECORD_SKIP_GRAPHQL=1.
#
# Usage, from the repository root:
#   scripts/record_runpod_catalog.sh
# It prompts for the key and does not echo it. With RUNPOD_API_KEY already in
# the environment it uses that instead; `ps -E` can then show the key on this
# script's own process, which the prompt avoids.
#
# Output, in ./tmp/runpod_catalog (RECORD_OUT changes it):
#   catalog_gpus_secure.json, catalog_gpus_community.json
#       a handful of GPUs, entries unedited, the same ids in both files:
#       the test fixtures for issue 40
#   full/    every v2 response, and both GraphQL responses, unedited
# stdout: one summary to paste into the ticket.
#
# Optional environment:
#   RECORD_OUT            output directory
#   RECORD_SKIP_GRAPHQL   1 skips the GraphQL requests and the comparison
#   RECORD_MAX_FIXTURE    most GPUs in the two fixture files (default 8)
#
# Needs bash 3.2+, curl and jq. The key never appears on a command line, in a
# URL, in output or in a file: curl reads the Authorization header from stdin
# (GraphQL takes the same Bearer header, so no `?api_key=` URL), and the key
# leaves the environment before any child process starts. Before it finishes,
# the script looks for the key in every file it wrote and deletes them if one
# holds it.

# The xtrace check comes first: `bash -x` would print the key.
case $- in
  *x*) echo "refusing to run under xtrace: it would print the API key" >&2; exit 2 ;;
esac

set -euo pipefail
ulimit -c 0

V2=https://api.runpod.io/v2
GQL=https://api.runpod.io/graphql
# curl -q must come first: it skips ~/.curlrc, which could trace or proxy the
# Authorization header.
CURL_SAFETY=(-q --proto =https)
# Test hook: point both APIs at a local fake. Only loopback is accepted, so the
# key can never be sent anywhere but Runpod or this machine.
if [[ -n ${RECORD_API_BASE:-} ]]; then
  if [[ ! $RECORD_API_BASE =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "RECORD_API_BASE must be http://127.0.0.1:<port> or http://localhost:<port>" >&2
    exit 2
  fi
  V2=$RECORD_API_BASE/v2
  GQL=$RECORD_API_BASE/graphql
  CURL_SAFETY=(-q --proto =http --noproxy '*')
fi

OUT=${RECORD_OUT:-tmp/runpod_catalog}
SKIP_GQL=${RECORD_SKIP_GRAPHQL:-}
MAX_FIXTURE=${RECORD_MAX_FIXTURE:-8}

for tool in curl jq; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 2; }
done
[[ $MAX_FIXTURE =~ ^[1-9][0-9]*$ ]] || { echo "RECORD_MAX_FIXTURE takes a positive whole number" >&2; exit 2; }
case $SKIP_GQL in "" | 1) ;; *) echo "RECORD_SKIP_GRAPHQL must be empty or 1" >&2; exit 2 ;; esac

# The key lives in an unexported variable, so no child process inherits it.
unset _RECORD_KEY
if [[ -n ${RUNPOD_API_KEY:-} ]]; then
  _RECORD_KEY=$RUNPOD_API_KEY
  unset RUNPOD_API_KEY
elif [[ -t 0 ]]; then
  read -rsp "Runpod API key (not echoed): " _RECORD_KEY
  echo >&2
else
  echo "no key: run from a terminal to be prompted, or set RUNPOD_API_KEY" >&2
  exit 2
fi
declare +x _RECORD_KEY

# The key goes into a curl config line; a quote or backslash would break it.
if [[ ! $_RECORD_KEY =~ ^[A-Za-z0-9_.-]+$ ]]; then
  echo "the key has characters outside [A-Za-z0-9_.-]; refusing to use it" >&2
  exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ex_atlas_record.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT/full"
RESP=$WORK/resp.json

# Today's query from lib/ex_atlas/providers/runpod.ex, verbatim.
GQL_CURRENT='query AtlasGpuTypes {
  gpuTypes {
    id
    displayName
    memoryInGb
    secureCloud
    communityCloud
    lowestPrice(input: {gpuCount: 1}) {
      minimumBidPrice
      uninterruptablePrice
    }
    stockStatus
  }
}'
GQL_FIXED='query AtlasGpuTypesFixed {
  gpuTypes {
    id
    displayName
    memoryInGb
    secureCloud
    communityCloud
    lowestPrice(input: {gpuCount: 1}) {
      minimumBidPrice
      uninterruptablePrice
      stockStatus
    }
  }
}'

# api METHOD URL OUTFILE [BODY_FILE] -> prints the HTTP status. It retries a
# 429, a 5xx and a dropped connection twice. The Authorization header comes from
# stdin (curl --config -), so the key never reaches argv, where `ps` shows it.
api() {
  local method=$1 url=$2 out=$3 body=${4:-} attempt code=000
  local args=("${CURL_SAFETY[@]}" --config - -sS -m 60 -o "$out" -w '%{http_code}'
    -X "$method" -H 'Accept: application/json')
  if [[ -n $body ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  for attempt in 1 2 3; do
    : >"$out"
    code=$(printf 'header = "Authorization: Bearer %s"\n' "$_RECORD_KEY" | curl "${args[@]}" "$url" 2>/dev/null) || code=000
    case $code in
      429 | 5* | 000) [[ $attempt == 3 ]] || sleep $((attempt * 3)) ;;
      *) break ;;
    esac
  done
  echo "$code"
}

# The error's own words, never the whole body, with control characters removed.
problem() {
  jq -r '[.title, .detail, .message, (.errors // [] | if type == "array" then map(if type == "object" then (.message // tostring) else tostring end) | join("; ") else tostring end)]
         | map(select(. != null and . != "")) | join(": ")' "$1" 2>/dev/null |
    tr -d '\000-\037\177' | head -c 300 || true
}

say() { printf '%s\n' "$*"; }

# --- v2 catalog: SECURE and COMMUNITY -----------------------------------------

V2_STATUS_SECURE=""
V2_STATUS_COMMUNITY=""
for cloud in SECURE COMMUNITY; do
  lower=$(printf '%s' "$cloud" | tr '[:upper:]' '[:lower:]')
  file=$OUT/full/v2_catalog_gpus_$lower.json
  code=$(api GET "$V2/catalog/gpus?include=AVAILABILITY&product=POD&cloud=$cloud" "$file")
  case $cloud in SECURE) V2_STATUS_SECURE=$code ;; *) V2_STATUS_COMMUNITY=$code ;; esac
  case $code in
    200) ;;
    401 | 403) echo "Runpod refused the key for the $cloud catalog (HTTP $code): $(problem "$file")" >&2; exit 1 ;;
    *) echo "the $cloud catalog answered HTTP $code: $(problem "$file")" >&2; exit 1 ;;
  esac
  if ! jq -e '.gpus | type == "array"' "$file" >/dev/null 2>&1; then
    echo "the $cloud catalog answered 200 without a \"gpus\" list" >&2
    exit 1
  fi
done
SEC=$OUT/full/v2_catalog_gpus_secure.json
COM=$OUT/full/v2_catalog_gpus_community.json

# --- GraphQL: today's query and the corrected one -----------------------------

GQL_STATUS_CURRENT="skipped"
GQL_STATUS_FIXED="skipped"
GQL_CUR=$OUT/full/graphql_current.json
GQL_FIX=$OUT/full/graphql_fixed.json
if [[ -z $SKIP_GQL ]]; then
  jq -n --arg q "$GQL_CURRENT" '{query: $q, variables: {}}' >"$WORK/gql_current_body.json"
  jq -n --arg q "$GQL_FIXED" '{query: $q, variables: {}}' >"$WORK/gql_fixed_body.json"
  GQL_STATUS_CURRENT=$(api POST "$GQL" "$GQL_CUR" "$WORK/gql_current_body.json")
  GQL_STATUS_FIXED=$(api POST "$GQL" "$GQL_FIX" "$WORK/gql_fixed_body.json")
fi

# --- fixture selection ---------------------------------------------------------

# The fixtures hold up to RECORD_MAX_FIXTURE GPUs that cover the shapes the
# translation must handle: each stock level, each cloud combination, no
# cudaVersions, a null pool, no serverless price. RTX 4090 goes first when
# present. Entries are copied as recorded, never edited.
jq -n --slurpfile s "$SEC" --slurpfile c "$COM" --argjson max "$MAX_FIXTURE" '
  def by_id(f): f | map({key: .id, value: .}) | from_entries;
  ($s[0].gpus | by_id(.)) as $S | ($c[0].gpus | by_id(.)) as $C |
  ([($s[0].gpus + $c[0].gpus)[].id] | unique) as $ids |
  def best($e):
    [ (if $e.secure    == true then ($S[$e.id].availability // "NONE") else empty end),
      (if $e.community == true then ($C[$e.id].availability // "NONE") else empty end) ]
    | if index("HIGH") then "HIGH" elif index("MEDIUM") then "MEDIUM"
      elif index("LOW") then "LOW" elif length > 0 then "NONE" else "NOCLOUD" end;
  def tags($id):
    ($S[$id] // $C[$id]) as $e
    | ["stock-" + best($e),
       "clouds-" + ([$e.secure, $e.community] | map(tostring) | join("-")),
       (if ($S[$id] // $C[$id] | has("cudaVersions") | not) then "no-cuda" else empty end),
       (if $e.pool == null then "null-pool" else empty end),
       (if ($e.price.serverless == null) then "no-serverless-price" else empty end),
       (if (($S[$id] // {}) | has("dataCenters") | not) and (($C[$id] // {}) | has("dataCenters") | not) then "no-datacenters" else empty end),
       (if ($S[$id] == null or $C[$id] == null) then "one-response-only" else empty end)];
  ([$ids[] | select(. == "NVIDIA GeForce RTX 4090")] + $ids) as $order |
  (reduce $order[] as $id ({picked: [], seen: {}};
    if (.picked | length) >= $max or (.picked | index($id)) then .
    else .seen as $seen | (tags($id) | map(select(. as $t | $seen | has($t) | not))) as $new
      | if ($new | length) > 0 or ($id == "NVIDIA GeForce RTX 4090")
        then .picked += [$id] | .seen += (tags($id) | map({key: ., value: true}) | from_entries)
        else . end
    end)) | .picked' >"$WORK/picked.json" 2>"$WORK/picked.err" || {
  echo "could not choose fixture GPUs: $(head -c 300 "$WORK/picked.err")" >&2
  exit 1
}

for lower in secure community; do
  src=$OUT/full/v2_catalog_gpus_$lower.json
  jq --slurpfile p "$WORK/picked.json" '{gpus: [.gpus[] | select(.id as $i | $p[0] | index($i))]}' "$src" \
    >"$OUT/catalog_gpus_$lower.json"
done

# --- summary -------------------------------------------------------------------

say "== Runpod catalog recording $(date -u +%Y-%m-%dT%H:%MZ) =="
say "HTTP: v2 SECURE $V2_STATUS_SECURE, v2 COMMUNITY $V2_STATUS_COMMUNITY, GraphQL today's query $GQL_STATUS_CURRENT, GraphQL corrected query $GQL_STATUS_FIXED"
say "v2 GPUs: $(jq '.gpus | length' "$SEC") in the SECURE read, $(jq '.gpus | length' "$COM") in the COMMUNITY read"
say "fixture GPUs ($(jq length "$WORK/picked.json")): $(jq -r 'join("; ")' "$WORK/picked.json")"
say ""
say "== v2 shape check against the OpenAPI GpuType schema =="
jq -n -r --slurpfile s "$SEC" --slurpfile c "$COM" '
  def req: ["id","name","pool","manufacturer","memory","secure","community","price","maxCount"];
  def known: req + ["availability","dataCenters","cudaVersions"];
  ($s[0].gpus + $c[0].gpus) as $all |
  "entries missing a required key: \([$all[] | select(. as $e | req | map(in($e) | not) | any)] | length)",
  "keys outside the schema: \([$all[] | keys[]] | unique | map(select(. as $k | known | index($k) | not)) | join(",") | if . == "" then "none" else . end)",
  "availability values seen: \([$all[] | .availability] | unique | map(. // "absent") | join(","))",
  "data center availability values seen: \([$all[] | .dataCenters[]? | .availability] | unique | join(","))",
  "entries with no cudaVersions: \([$all[] | select(has("cudaVersions") | not)] | length)",
  "entries with null pool: \([$all[] | select(.pool == null)] | length)",
  "entries with no price.serverless: \([$all[] | select(.price.serverless == null)] | length)",
  "entries with no dataCenters: \([$all[] | select(has("dataCenters") | not)] | length)",
  "entries with neither secure nor community: \([$all[] | select(.secure != true and .community != true)] | length)",
  "price.secure and price.community types: \([$all[] | (.price.secure | type), (.price.community | type)] | unique | join(","))",
  "GPUs in one read only: \(([$s[0].gpus[].id] | unique) as $a | ([$c[0].gpus[].id] | unique) as $b | (($a - $b) + ($b - $a)) | length)"'

if [[ -z $SKIP_GQL ]]; then
  say ""
  say "== GraphQL answers =="
  for which in CUR FIX; do
    file=$GQL_CUR
    label="today's query"
    status=$GQL_STATUS_CURRENT
    if [[ $which == FIX ]]; then file=$GQL_FIX; label="corrected query"; status=$GQL_STATUS_FIXED; fi
    if jq -e '(.errors // []) | length > 0' "$file" >/dev/null 2>&1; then
      say "$label: HTTP $status, GraphQL errors: $(problem "$file")"
    elif jq -e '.data.gpuTypes | type == "array"' "$file" >/dev/null 2>&1; then
      say "$label: HTTP $status, $(jq '.data.gpuTypes | length' "$file") GPU types, stockStatus at GpuType level on $(jq '[.data.gpuTypes[] | select(has("stockStatus"))] | length' "$file"), under lowestPrice on $(jq '[.data.gpuTypes[] | select(.lowestPrice != null and (.lowestPrice | has("stockStatus")))] | length' "$file")"
    else
      say "$label: HTTP $status, no gpuTypes list: $(problem "$file")"
    fi
  done

  say ""
  say "== Side by side: v2 against GraphQL (corrected query) =="
  say "v2 price is the lower list price of the clouds the GPU is on; v2 stock is the best level of those clouds."
  if jq -e '.data.gpuTypes | type == "array"' "$GQL_FIX" >/dev/null 2>&1; then
    jq -n -r --slurpfile s "$SEC" --slurpfile c "$COM" --slurpfile g "$GQL_FIX" '
      ($s[0].gpus | map({key: .id, value: .}) | from_entries) as $S |
      ($c[0].gpus | map({key: .id, value: .}) | from_entries) as $C |
      ($g[0].data.gpuTypes | map({key: .id, value: .}) | from_entries) as $G |
      ([$S, $C, $G | keys[]] | unique) as $ids |
      def lvl: {"HIGH": "High", "MEDIUM": "Medium", "LOW": "Low", "NONE": "Unavailable"};
      def flags($e): if $e == null then "-" else (if $e.secure then "S" else "" end) + (if $e.community then "C" else "" end) end;
      def v2e($id): $S[$id] // $C[$id];
      def v2price($id):
        v2e($id) as $e | if $e == null then null else
          [ (if $e.secure == true then $e.price.secure // empty else empty end),
            (if $e.community == true then $e.price.community // empty else empty end) ]
          | if length == 0 then null else min end end;
      def v2stock($id):
        v2e($id) as $e | if $e == null then null else
          [ (if $e.secure == true then ($S[$id].availability // "NONE") else empty end),
            (if $e.community == true then ($C[$id].availability // "NONE") else empty end) ]
          | if length == 0 then null
            else (if index("HIGH") then "HIGH" elif index("MEDIUM") then "MEDIUM" elif index("LOW") then "LOW" else "NONE" end) end end;
      (["id", "name v2", "name gql", "GB v2", "GB gql", "clouds v2", "clouds gql", "price v2", "price gql", "stock v2", "stock gql", "differs"] | @tsv),
      ($ids[] as $id
        | v2e($id) as $e | $G[$id] as $q
        | (v2price($id)) as $p | (v2stock($id)) as $st
        | ($q.lowestPrice.uninterruptablePrice) as $gp
        | ($q.lowestPrice.stockStatus) as $gs
        | ([ (if ($e.name // null) != ($q.displayName // null) then "name" else empty end),
             (if ($e.memory // null) != ($q.memoryInGb // null) then "memory" else empty end),
             (if flags($e) != (if $q == null then "-" else (if $q.secureCloud then "S" else "" end) + (if $q.communityCloud then "C" else "" end) end) then "clouds" else empty end),
             (if ($p // null) != ($gp // null) then "price" else empty end),
             (if (lvl[$st // ""] // null) != ($gs // null) then "stock" else empty end) ] | join("+")) as $d
        | [$id, ($e.name // "-"), ($q.displayName // "-"), ($e.memory // "-"), ($q.memoryInGb // "-"),
           flags($e), (if $q == null then "-" else (if $q.secureCloud then "S" else "" end) + (if $q.communityCloud then "C" else "" end) end),
           ($p // "-"), ($gp // "-"), ($st // "-"), ($gs // "-"), (if $d == "" then "same" else $d end)] | map(tostring) | @tsv)' \
      | column -t -s "$(printf '\t')"
    say ""
    jq -n -r --slurpfile s "$SEC" --slurpfile c "$COM" --slurpfile g "$GQL_FIX" '
      ($g[0].data.gpuTypes | length) as $n
      | "GraphQL GPU types: \($n); ids only in v2: \(([$s[0].gpus[].id, $c[0].gpus[].id] | unique) - [$g[0].data.gpuTypes[].id] | length); ids only in GraphQL: \(([$g[0].data.gpuTypes[].id] - ([$s[0].gpus[].id, $c[0].gpus[].id] | unique)) | length)"'
  else
    say "no comparison: the corrected GraphQL query returned no gpuTypes list"
  fi
fi

# --- the key must be in no file ------------------------------------------------

# The key reaches grep through a process substitution, never argv.
if grep -rqF -f <(printf '%s\n' "$_RECORD_KEY") "$OUT" 2>/dev/null; then
  rm -rf "$OUT"
  echo "the API key appeared in a recorded file; deleted $OUT" >&2
  exit 1
fi

say ""
say "files: $OUT/catalog_gpus_secure.json, $OUT/catalog_gpus_community.json (fixtures), $OUT/full/ (everything)"
