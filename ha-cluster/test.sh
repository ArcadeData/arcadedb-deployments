#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
NODE1_URL="${NODE1_URL:-http://localhost:2480}"
NODE2_URL="${NODE2_URL:-http://localhost:2481}"
NODE3_URL="${NODE3_URL:-http://localhost:2482}"
DB="ha_test_$$"
PASS_COUNT=0
FAIL_COUNT=0

command_on() {
    local url="$1"
    local sql="$2"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$url/api/v1/command/$DB"
}

query_on() {
    local url="$1"
    local sql="$2"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$url/api/v1/query/$DB"
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
        "$NODE1_URL/api/v1/server" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== ArcadeDB HA Cluster Test ==="
echo ""

echo "Creating test database on node-0 ..."
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"create database $DB\"}" \
    "$NODE1_URL/api/v1/server" > /dev/null

command_on "$NODE1_URL" "create document type Message" > /dev/null
command_on "$NODE1_URL" "insert into Message set text = 'hello-ha'" > /dev/null

echo "Waiting for replication ..."
sleep 2

echo "Reading from node-1 ..."
RESULT2=$(query_on "$NODE2_URL" "select text from Message" | jq -r '.result[0].text')
check "record readable from node-1" "$RESULT2" "hello-ha"

echo "Reading from node-2 ..."
RESULT3=$(query_on "$NODE3_URL" "select text from Message" | jq -r '.result[0].text')
check "record readable from node-2" "$RESULT3" "hello-ha"

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
