#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

FLOCI_URL="http://floci-az:4577/devstoreaccount1"
CONTAINER="arcadedb"
FILER_URL="http://seaweedfs-filer:8888"
MOUNT_DIR="/buckets/arcadedb"
TOOLBOX="az-toolbox"
TOOLBOX_IMAGE="curlimages/curl:8.10.1"
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
# file on the filer has a blob with the same name and size.
wait_for_remote_sync() {
    local attempt missing
    for attempt in $(seq 1 60); do
        missing=$(comm -23 <(filer_list_sizes | sort) <(blob_list_sizes | sort))
        [ -z "$missing" ] && return 0
        sleep 2
    done
    echo "ERROR: remote sync did not catch up; not yet in Blob:"
    echo "$missing"
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
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
