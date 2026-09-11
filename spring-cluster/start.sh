#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building and starting 3-node spring-cluster..."
docker compose up -d --build

nodes=("http://localhost:8080" "http://localhost:8081" "http://localhost:8082")

echo "Waiting for nodes to become healthy..."
for url in "${nodes[@]}"; do
  for i in $(seq 1 60); do
    if curl -sf "$url/api/health" >/dev/null 2>&1; then
      echo "  $url is healthy"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "Timeout waiting for $url" >&2
      exit 1
    fi
    sleep 2
  done
done

echo "Waiting for a single leader to be elected..."
for i in $(seq 1 30); do
  leaders=0
  found_leader=""
  for url in "${nodes[@]}"; do
    if [ "$(curl -sf "$url/api/cluster/status" 2>/dev/null | jq -r '.leader' 2>/dev/null || echo false)" = "true" ]; then
      leaders=$((leaders + 1))
      found_leader="$url"
    fi
  done
  if [ "$leaders" -eq 1 ]; then
    leader_url="$found_leader"
    break
  fi
  sleep 2
done

if [ -z "${leader_url:-}" ]; then
  echo "No single leader elected within timeout" >&2
  exit 1
fi
echo "Leader elected: $leader_url"

# The leader seeds schema + sample data only after it wins the election, so a
# cluster that has a leader is not yet a cluster that has data. Wait for the
# seed to land before handing over, otherwise the first read can hit an empty
# database.
echo "Waiting for the leader to seed sample data..."
for i in $(seq 1 60); do
  if [ "$(curl -sf "$leader_url/api/recommendations/collaborative/u1" 2>/dev/null | jq -r 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    echo "Cluster is up with one leader and seeded data."
    exit 0
  fi
  sleep 2
done

echo "Leader did not seed sample data within timeout" >&2
exit 1
