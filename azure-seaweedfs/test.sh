#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
ARCADEDB_URL="${ARCADEDB_URL:-http://localhost:2480}"
DB="azure_test_$$"
FLOCI_URL="http://floci-az:4577/devstoreaccount1"
CONTAINER="arcadedb"
FILER_URL="http://seaweedfs-filer:8888"
MOUNT_DIR="/buckets/arcadedb"
TOOLBOX="az-toolbox"
TOOLBOX_IMAGE="curlimages/curl:8.10.1"
# Remote sync uploads whole files, so every append to a Raft log segment or a
# WAL file re-uploads the object, and Blob trails the filer by minutes.
SYNC_TIMEOUT_SECONDS="${SYNC_TIMEOUT_SECONDS:-600}"
PASS_COUNT=0
FAIL_COUNT=0

check() {
    local desc="$1"
    local result="$2"
    local expected="$3"
    if [ "$result" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc"
        echo "        expected: $expected"
        echo "        got:      $result"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# floci-az and the SeaweedFS filer are only reachable inside the cluster, so
# every call to them goes through a small curl pod that lives for the test run.
start_toolbox() {
    kubectl delete pod "$TOOLBOX" --ignore-not-found --wait=true > /dev/null
    kubectl run "$TOOLBOX" --image="$TOOLBOX_IMAGE" --restart=Never \
        --command -- sleep 3600 > /dev/null
    kubectl wait --for=condition=Ready "pod/$TOOLBOX" --timeout=120s > /dev/null
}

incluster_curl() {
    kubectl exec "$TOOLBOX" -- curl -sS "$@"
}

cleanup() {
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"drop database $DB\"}" \
        "$ARCADEDB_URL/api/v1/server" > /dev/null 2>&1 || true
    kubectl delete pod "$TOOLBOX" --ignore-not-found --wait=false > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Blob names in the floci-az container, one per line, as "<name> <size>".
blob_list_sizes() {
    incluster_curl "$FLOCI_URL/$CONTAINER?restype=container&comp=list" \
        | tr '<' '\n' \
        | awk -F'>' '$1 == "Name" { name = $2 } $1 == "Content-Length" { print name, $2 }'
}

blob_list() {
    blob_list_sizes | cut -d' ' -f1
}

# Regular files under the mounted directory on the filer, as "<path> <size>",
# path relative to the mounted directory.
filer_list_sizes() {
    local dir="${1:-$MOUNT_DIR}"
    local listing
    listing=$(incluster_curl -H "Accept: application/json" "$FILER_URL$dir/?limit=10000")
    echo "$listing" | jq -r '.Entries // [] | .[]
        | select((.Mode / 2147483648 | floor) % 2 == 0)
        | "\(.FullPath) \(.FileSize)"' \
        | sed "s|^$MOUNT_DIR/||"
    local sub
    for sub in $(echo "$listing" | jq -r '.Entries // [] | .[]
            | select((.Mode / 2147483648 | floor) % 2 == 1) | .FullPath'); do
        filer_list_sizes "$sub"
    done
}

filer_put() {
    local path="$1"
    local content="$2"
    kubectl exec "$TOOLBOX" -- sh -c \
        "printf '%s' '$content' | curl -sS -F file=@- '$FILER_URL$path'" > /dev/null
}

# Remote sync is asynchronous. Before trusting Blob, wait until every regular
# file on the filer has a blob with the same name and size. Empty files are
# left out: remote sync never uploads them (ArcadeDB's only one is the
# database.lck lock file, which it recreates on open).
wait_for_remote_sync() {
    local deadline missing
    deadline=$(( $(date +%s) + SYNC_TIMEOUT_SECONDS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        missing=$(comm -23 <(filer_list_sizes | grep -v " 0$" | sort) <(blob_list_sizes | sort))
        [ -z "$missing" ] && return 0
        sleep 5
    done
    echo "ERROR: remote sync did not catch up in ${SYNC_TIMEOUT_SECONDS}s; not yet in Blob:"
    echo "$missing"
    return 1
}

command_on() {
    local sql="$1"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$ARCADEDB_URL/api/v1/command/$DB"
}

query_on() {
    local sql="$1"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$ARCADEDB_URL/api/v1/query/$DB"
}

query_with_retry() {
    local expected="$1"
    local result attempt
    for attempt in $(seq 1 30); do
        result="$(query_on "select text from Message where text = '$expected'" 2>/dev/null \
            | jq -r '.result[0].text // empty' 2>/dev/null)" || result=""
        [ "$result" = "$expected" ] && { echo "$result"; return 0; }
        sleep 2
    done
    echo "${result:-}"
    return 1
}

# The create-database call is answered as soon as the leader commits the Raft
# install-database entry; the node behind the port-forward may apply it a
# moment later. Wait for the database to be open on that node.
wait_for_database() {
    local attempt
    for attempt in $(seq 1 30); do
        query_on "select from schema:types" > /dev/null 2>&1 && return 0
        sleep 1
    done
    echo "ERROR: database $DB is not available on the node behind the port-forward"
    return 1
}

ha_wait_for_nodes() {
    local expected="$1"
    local result attempt
    for attempt in $(seq 1 40); do
        result=$(curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
            "$ARCADEDB_URL/api/v1/server?mode=cluster" \
            | jq '(.ha.network.replicas | length) + 1' 2>/dev/null) \
            || result=0
        [ "$result" = "$expected" ] && { echo "$result"; return 0; }
        sleep 3
    done
    echo "${result:-0}"
    return 1
}

# Pod name of the current Raft leader, as seen by the node behind the
# port-forward ("arcadedb-1 (arcadedb-1.arcadedb...:2480)" -> "arcadedb-1").
leader_pod() {
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        "$ARCADEDB_URL/api/v1/server?mode=cluster" \
        | jq -r '.ha.leader // empty' | cut -d' ' -f1
}

wait_for_new_leader() {
    local old="$1"
    local leader attempt
    for attempt in $(seq 1 40); do
        leader="$(leader_pod 2>/dev/null || true)"
        if [ -n "$leader" ] && [ "$leader" != "$old" ]; then
            echo yes
            return 0
        fi
        sleep 3
    done
    echo "no (leader: ${leader:-none})"
    return 1
}

# kubectl port-forward to a Service sticks to the one pod it picked at start
# and dies with it. Replace start.sh's port-forward (same PID file, so stop.sh
# still cleans up) with one to a pod that is not being deleted, and wait until
# it answers.
restart_port_forward() {
    local avoid="$1"
    local pid_file=".port-forward.pid"
    local target attempt
    target=$(for n in 0 1 2; do echo "arcadedb-$n"; done | grep -vx "$avoid" | head -1)
    [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null || true
    for attempt in $(seq 1 20); do
        kubectl port-forward "pod/$target" 2480:2480 > /dev/null 2>&1 &
        echo $! > "$pid_file"
        sleep 3
        if curl -sf "$ARCADEDB_URL/api/v1/ready" > /dev/null 2>&1; then
            return 0
        fi
        kill "$(cat "$pid_file")" 2>/dev/null || true
    done
    echo "ERROR: no ArcadeDB node reachable through a new port-forward"
    return 1
}

echo "=== ArcadeDB on SeaweedFS + Azure Blob Test ==="
echo ""

start_toolbox

echo "Remote sync: filer -> floci-az Blob ..."
filer_put "$MOUNT_DIR/_canary/hello.txt" "hello-azure"
wait_for_remote_sync || true
check "canary blob in floci-az" "$(blob_list | grep -c '^_canary/hello.txt$' || true)" "1"
check "canary content" "$(incluster_curl "$FLOCI_URL/$CONTAINER/_canary/hello.txt" || true)" "hello-azure"
incluster_curl -X DELETE "$FILER_URL$MOUNT_DIR/_canary/?recursive=true" > /dev/null || true

echo ""
echo "Creating test database ..."
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"create database $DB\"}" \
    "$ARCADEDB_URL/api/v1/server" > /dev/null || true
wait_for_database || true

command_on "create document type Message" > /dev/null || true
command_on "insert into Message set text = 'hello-azure'" > /dev/null || true

echo "Reading record back ..."
check "record readable from cluster" "$(query_with_retry hello-azure || true)" "hello-azure"
check "3 HA nodes online" "$(ha_wait_for_nodes 3 || true)" "3"

echo ""
echo "ArcadeDB files in Blob ..."
check "Blob caught up with the filer" "$(wait_for_remote_sync >&2 && echo yes || echo no)" "yes"
BLOBS="$(blob_list)"
for n in 0 1 2; do
    check "replica $n database files in Blob" \
        "$(echo "$BLOBS" | grep -q "^arcadedb-$n/data/$DB/" && echo yes || echo no)" "yes"
    check "replica $n raft log in Blob" \
        "$(echo "$BLOBS" | grep -q "^arcadedb-$n/raft/." && echo yes || echo no)" "yes"
done

echo ""
echo "Leader failover ..."
wait_for_remote_sync > /dev/null || true
OLD_LEADER="$(leader_pod || true)"
echo "Deleting leader pod $OLD_LEADER ..."
kubectl delete pod "$OLD_LEADER" --wait=false > /dev/null
restart_port_forward "$OLD_LEADER" || true
check "new leader elected" "$(wait_for_new_leader "$OLD_LEADER" || true)" "yes"
check "record survives failover" "$(query_with_retry hello-azure || true)" "hello-azure"
kubectl wait --for=condition=Ready "pod/$OLD_LEADER" --timeout=180s > /dev/null || true
check "3 HA nodes online after failover" "$(ha_wait_for_nodes 3 || true)" "3"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
