#!/usr/bin/env bash
set -euo pipefail

n0="http://localhost:8080"
n1="http://localhost:8081"
n2="http://localhost:8082"

echo "Check 1: exactly one leader"
leaders=0
for url in "$n0" "$n1" "$n2"; do
  if [ "$(curl -sf "$url/api/cluster/status" | jq -r '.leader')" = "true" ]; then
    leaders=$((leaders + 1))
  fi
done
if [ "$leaders" -ne 1 ]; then
  echo "  FAIL: expected 1 leader, found $leaders" >&2
  exit 1
fi
echo "  PASS: exactly one leader"

echo "Check 2: identical collaborative reads across all nodes (replication)"
r0=$(curl -sf "$n0/api/recommendations/collaborative/u1" | jq -S .)
r1=$(curl -sf "$n1/api/recommendations/collaborative/u1" | jq -S .)
r2=$(curl -sf "$n2/api/recommendations/collaborative/u1" | jq -S .)
if [ "$r0" != "$r1" ] || [ "$r1" != "$r2" ]; then
  echo "  FAIL: reads differ across nodes" >&2
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
