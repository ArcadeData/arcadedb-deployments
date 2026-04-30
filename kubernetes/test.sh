#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
ARCADEDB_URL="${ARCADEDB_URL:-http://localhost:2480}"
DB="k8s_test_$$"
PASS_COUNT=0
FAIL_COUNT=0

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

cleanup() {
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"drop database $DB\"}" \
        "$ARCADEDB_URL/api/v1/server" > /dev/null 2>&1 || true
}
trap cleanup EXIT

query_with_retry() {
    local expected="$1"
    local result attempt
    for attempt in $(seq 1 15); do
        result="$(query_on "select text from Message" 2>/dev/null \
            | jq -r '.result[0].text // empty' 2>/dev/null)" || result=""
        [ "$result" = "$expected" ] && { echo "$result"; return 0; }
        sleep 2
    done
    echo "${result:-}"
    return 1
}

echo "=== ArcadeDB Kubernetes HA Cluster Test ==="
echo ""

echo "Creating test database ..."
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"create database $DB\"}" \
    "$ARCADEDB_URL/api/v1/server" > /dev/null

command_on "create document type Message" > /dev/null
command_on "insert into Message set text = 'hello-k8s'" > /dev/null

echo "Reading record back ..."
RESULT="$(query_with_retry "hello-k8s")" || RESULT=""
check "record readable from cluster" "$RESULT" "hello-k8s"

echo "Checking HA cluster has 3 online nodes ..."
echo "DEBUG: raw /api/v1/server response:"
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" "$ARCADEDB_URL/api/v1/server" | jq . || true
echo ""

ha_wait_for_nodes() {
    local expected="$1"
    local result attempt
    for attempt in $(seq 1 20); do
        result=$(curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
            "$ARCADEDB_URL/api/v1/server" \
            | jq '(.ha.network.replicas | length) + 1' 2>/dev/null) \
            || result=0
        [ "$result" = "$expected" ] && { echo "$result"; return 0; }
        sleep 3
    done
    echo "${result:-0}"
    return 1
}
ONLINE_NODES=$(ha_wait_for_nodes "3") || ONLINE_NODES=0
check "3 HA nodes online" "$ONLINE_NODES" "3"

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
