#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
NODE1_URL="${NODE1_URL:-http://localhost:2480}"
NODE2_URL="${NODE2_URL:-http://localhost:2481}"
NODE3_URL="${NODE3_URL:-http://localhost:2482}"
MAX_ATTEMPTS=60

wait_for_node() {
    local url="$1"
    local name="$2"
    local attempt=0
    echo "Waiting for $name at $url ..."
    while ! curl -sf "$url/api/v1/ready" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            echo "ERROR: $name did not become ready after $MAX_ATTEMPTS attempts"
            exit 1
        fi
        sleep 2
    done
    echo "$name is ready"
}

echo "Starting ArcadeDB HA cluster (3 nodes) ..."
docker compose up -d

wait_for_node "$NODE1_URL" "node1"
wait_for_node "$NODE2_URL" "node2"
wait_for_node "$NODE3_URL" "node3"

echo ""
echo "Cluster status:"
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" "$NODE1_URL/api/v1/server" | jq .

echo ""
echo "HA cluster is up and ready."
