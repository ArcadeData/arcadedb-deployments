#!/usr/bin/env bash
set -euo pipefail

n0="http://localhost:8080"
n1="http://localhost:8081"
n2="http://localhost:8082"

echo "Check 1: exactly one leader"
leaders=0
for url in "$n0" "$n1" "$n2"; do
  if [ "$(curl -sf "$url/api/cluster/status" 2>/dev/null | jq -r '.leader' 2>/dev/null || echo false)" = "true" ]; then
    leaders=$((leaders + 1))
  fi
done
if [ "$leaders" -ne 1 ]; then
  echo "  FAIL: expected 1 leader, found $leaders" >&2
  exit 1
fi
echo "  PASS: exactly one leader"

echo "Check 2: identical collaborative reads across all nodes (replication)"
# Replication is asynchronous: a follower can still be empty, or serve an error,
# for a moment after the leader commits the seed. Retry until the three nodes
# agree, and only fail if they never do.
read_node() {
  curl -sf "$1/api/recommendations/collaborative/u1" 2>/dev/null | jq -S . 2>/dev/null || echo "unavailable"
}
for i in $(seq 1 30); do
  r0=$(read_node "$n0")
  r1=$(read_node "$n1")
  r2=$(read_node "$n2")
  if [ "$r0" = "$r1" ] && [ "$r1" = "$r2" ] && [ "$r0" != "unavailable" ] && [ "$r0" != "[]" ]; then
    break
  fi
  sleep 2
done
if [ "$r0" != "$r1" ] || [ "$r1" != "$r2" ] || [ "$r0" = "unavailable" ] || [ "$r0" = "[]" ]; then
  echo "  FAIL: reads did not converge across nodes" >&2
  echo "        n0: $r0" >&2
  echo "        n1: $r1" >&2
  echo "        n2: $r2" >&2
  exit 1
fi
echo "  PASS: identical reads on all 3 nodes"

echo "Check 3: top recommendation for u1 is Running Shoes"
top=$(echo "$r0" | jq -r '.[0].name')
if [ "$top" != "Running Shoes" ]; then
  echo "  FAIL: expected 'Running Shoes', got '$top'" >&2
  exit 1
fi
echo "  PASS: top recommendation is Running Shoes"

echo "All cluster checks passed."
