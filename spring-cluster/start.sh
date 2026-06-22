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
  for url in "${nodes[@]}"; do
    if [ "$(curl -sf "$url/api/cluster/status" | jq -r '.leader')" = "true" ]; then
      leaders=$((leaders + 1))
    fi
  done
  if [ "$leaders" -eq 1 ]; then
    echo "Cluster is up with one leader."
    exit 0
  fi
  sleep 2
done

echo "No single leader elected within timeout" >&2
exit 1
