#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

KIND_CLUSTER="${KIND_CLUSTER:-arcadedb-azure}"
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

# Blobs in the floci-az container, one per line, as "<name> <size>".
blob_list_sizes() {
    incluster_curl "$FLOCI_URL/$CONTAINER?restype=container&comp=list" |
        tr '<' '\n' |
        awk -F'>' '$1 == "Name" { name = $2 } $1 == "Content-Length" { print name, $2 }'
}

blob_list() {
    blob_list_sizes | cut -d' ' -f1
}

# Regular files under the mounted directory on the filer, as
# "<path> <size> <synced>", path relative to the mounted directory. synced is
# 1 when remote sync has handled the file's latest change: it uploaded it (or
# found the content unchanged) after the file was last modified, or the file
# came from Blob and was not modified since.
filer_state() {
    local dir="${1:-$MOUNT_DIR}"
    local listing
    listing=$(incluster_curl -H "Accept: application/json" "$FILER_URL$dir/?limit=10000")
    echo "$listing" | jq -r '.Entries // [] | .[]
        | select((.Mode / 2147483648 | floor) % 2 == 0)
        | (.Mtime | capture("^(?<s>[^.Z]+)(?<f>\\.[0-9]+)?Z$")
            | (.s + "Z" | fromdateiso8601) + (.f // "0" | tonumber)) as $mtime
        | (((.Remote.last_local_sync_ts_ns // 0) / 1e9 >= $mtime)
            or ((.Remote.remote_mtime // 0) >= $mtime)) as $synced
        | "\(.FullPath) \(.FileSize) \(if $synced then 1 else 0 end)"' |
        sed "s|^$MOUNT_DIR/||"
    local sub
    for sub in $(echo "$listing" | jq -r '.Entries // [] | .[]
            | select((.Mode / 2147483648 | floor) % 2 == 1) | .FullPath'); do
        filer_state "$sub"
    done
}

filer_put() {
    local path="$1"
    local content="$2"
    kubectl exec "$TOOLBOX" -- sh -c \
        "printf '%s' '$content' | curl -sS -F file=@- '$FILER_URL$path'" > /dev/null
}

# Remote sync is asynchronous. Before trusting Blob, wait until it mirrors the
# filer: remote sync has handled every file's latest change (ArcadeDB rewrites
# pages in place, so a matching size alone does not show that), every file has
# a blob of the same size, and no ArcadeDB blob is left over from a file the
# filer has deleted. Empty files are left out: remote sync never uploads them
# (ArcadeDB's only one is the database.lck lock file, which it recreates on
# open).
remote_sync_lag() {
    local filer blobs
    filer=$(filer_state)
    blobs=$(blob_list_sizes)
    if [ -z "$filer" ] || [ -z "$blobs" ]; then
        echo "(filer or Blob listing is empty)"
        return
    fi
    awk 'NR == FNR { size[$1] = $2; next }
        $2 != 0 && ($3 != 1 || !($1 in size) || size[$1] != $2) { print $1 }' \
        <(echo "$blobs") <(echo "$filer")
    awk 'NR == FNR { on_filer[$1] = 1; next }
        $1 ~ /^arcadedb-[0-9]+\// && !($1 in on_filer) { print $1 " (deleted on the filer)" }' \
        <(echo "$filer") <(echo "$blobs")
}

wait_for_remote_sync() {
    local deadline lag
    deadline=$(($(date +%s) + SYNC_TIMEOUT_SECONDS))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        lag=$(remote_sync_lag)
        [ -z "$lag" ] && return 0
        sleep 5
    done
    echo "ERROR: remote sync did not catch up in ${SYNC_TIMEOUT_SECONDS}s; not yet in Blob:"
    echo "$lag"
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
        result="$(query_on "select text from Message where text = '$expected'" 2> /dev/null |
            jq -r '.result[0].text // empty' 2> /dev/null)" || result=""
        [ "$result" = "$expected" ] && {
            echo "$result"
            return 0
        }
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
            "$ARCADEDB_URL/api/v1/server?mode=cluster" |
            jq '(.ha.network.replicas | length) + 1' 2> /dev/null) ||
            result=0
        [ "$result" = "$expected" ] && {
            echo "$result"
            return 0
        }
        sleep 3
    done
    echo "${result:-0}"
    return 1
}

# Pod name of the current Raft leader, as seen by the node behind the
# port-forward ("arcadedb-1 (arcadedb-1.arcadedb...:2480)" -> "arcadedb-1").
leader_pod() {
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        "$ARCADEDB_URL/api/v1/server?mode=cluster" |
        jq -r '.ha.leader // empty' | cut -d' ' -f1
}

wait_for_new_leader() {
    local old="$1"
    local leader attempt
    for attempt in $(seq 1 40); do
        leader="$(leader_pod 2> /dev/null || true)"
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
    [ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2> /dev/null || true
    for attempt in $(seq 1 20); do
        kubectl port-forward "pod/$target" 2480:2480 > /dev/null 2>&1 &
        echo $! > "$pid_file"
        sleep 3
        if curl -sf "$ARCADEDB_URL/api/v1/ready" > /dev/null 2>&1; then
            return 0
        fi
        kill "$(cat "$pid_file")" 2> /dev/null || true
    done
    echo "ERROR: no ArcadeDB node reachable through a new port-forward"
    return 1
}

# A deleted StatefulSet pod comes back under the same name; wait until the new
# one exists and is Ready.
wait_for_pod_ready() {
    local pod="$1"
    local attempt
    for attempt in $(seq 1 60); do
        kubectl get pod "$pod" > /dev/null 2>&1 && break
        sleep 2
    done
    kubectl wait --for=condition=Ready "pod/$pod" --timeout=300s > /dev/null
}

echo "=== ArcadeDB on SeaweedFS + Azure Blob Test ==="
echo ""

# The test deletes and scales pods. Make sure they are this scenario's, not
# the kubernetes/ scenario's (same release name, same namespace).
kubectl config use-context "kind-${KIND_CLUSTER}" > /dev/null

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
echo "Cold restart from Blob ..."
# Stop ArcadeDB first: shutting down flushes pages and rewrites WAL and Raft
# files, and those writes must reach Blob before anything is destroyed.
echo "Stopping ArcadeDB ..."
kubectl scale statefulset arcadedb --replicas=0 > /dev/null
kubectl wait --for=delete pod -l app=arcadedb --timeout=180s > /dev/null || true
if ! wait_for_remote_sync >&2; then
    # Wiping now would test the async-sync caveat, not the rebuild. Leave
    # SeaweedFS alone and bring ArcadeDB back.
    check "Blob caught up after ArcadeDB stopped" "no" "yes"
    kubectl scale statefulset arcadedb --replicas=3 > /dev/null
else
    check "Blob caught up after ArcadeDB stopped" "yes" "yes"
    # Every SeaweedFS component, the CSI mount service and remote sync keep
    # their state on emptyDir or in memory: deleting the pods leaves Blob as
    # the only copy of the data.
    echo "Wiping SeaweedFS ..."
    kubectl delete pod seaweedfs-master-0 seaweedfs-volume-0 seaweedfs-filer-0 > /dev/null
    kubectl delete pod -l app=seaweedfs-remote-sync > /dev/null
    kubectl delete pod -l app=arcadedb-mount > /dev/null
    for pod in seaweedfs-master-0 seaweedfs-volume-0 seaweedfs-filer-0; do
        wait_for_pod_ready "$pod" || true
    done
    # A fresh filer has no /buckets directory at all and answers with an
    # empty body, which counts as empty too.
    MOUNTED_ENTRIES=$(incluster_curl -H "Accept: application/json" "$FILER_URL/buckets/?limit=100" |
        jq -r --arg dir "$MOUNT_DIR" '[.Entries // [] | .[] | select(.FullPath == $dir)] | length' \
            2> /dev/null || echo error)
    check "filer is empty after the wipe" "${MOUNTED_ENTRIES:-0}" "0"
    echo "Mounting the Blob container again ..."
    check "Blob container mounted again" "$(./remote-setup.sh >&2 && echo yes || echo no)" "yes"
    # Remote sync exits while nothing is mounted and may be in a long restart
    # back-off by now. Restart it so it follows the new mount right away.
    kubectl delete pod -l app=seaweedfs-remote-sync > /dev/null
    wait_for_pod_ready "$(kubectl get pod -l app=arcadedb-mount -o name | head -1 | cut -d/ -f2)" || true
    echo "Starting ArcadeDB ..."
    kubectl scale statefulset arcadedb --replicas=3 > /dev/null
    kubectl rollout status statefulset/arcadedb --timeout=600s > /dev/null || true
    restart_port_forward "" || true
    check "leader elected after cold restart" "$([ -n "$(leader_pod || true)" ] && echo yes || echo no)" "yes"
    check "3 HA nodes online after cold restart" "$(ha_wait_for_nodes 3 || true)" "3"
    check "record restored from Blob" "$(query_with_retry hello-azure || true)" "hello-azure"
    command_on "insert into Message set text = 'after-restore'" > /dev/null || true
    check "write accepted after restore" "$(query_with_retry after-restore || true)" "after-restore"
    check "writes sync to Blob after restore" "$(wait_for_remote_sync >&2 && echo yes || echo no)" "yes"
fi

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
