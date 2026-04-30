#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

KIND_CLUSTER="${KIND_CLUSTER:-arcadedb}"
ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
ARCADEDB_URL="${ARCADEDB_URL:-http://localhost:2480}"
MAX_ATTEMPTS=90
PID_FILE=".port-forward.pid"

wait_for_ready() {
    local attempt=0
    echo "Waiting for ArcadeDB to become ready at ${ARCADEDB_URL} ..."
    while ! curl -sf --max-time 3 "${ARCADEDB_URL}/api/v1/ready" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            echo "ERROR: ArcadeDB did not become ready after ${MAX_ATTEMPTS} attempts"
            exit 1
        fi
        sleep 2
    done
    echo "ArcadeDB is ready."
}

# Create kind cluster if not already running
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
    echo "Kind cluster '${KIND_CLUSTER}' already exists, reusing."
else
    echo "Creating kind cluster '${KIND_CLUSTER}' ..."
    kind create cluster --name "${KIND_CLUSTER}"
fi

echo "Updating Helm dependencies ..."
helm dependency update .

echo "Creating ArcadeDB credentials secret ..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: arcadedb-credentials-secret
  namespace: default
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: arcadedb
    meta.helm.sh/release-namespace: default
type: Opaque
stringData:
  rootPassword: "${ARCADEDB_PASS}"
EOF

echo "Installing ArcadeDB Helm chart (3 replicas, this may take a few minutes) ..."
helm install arcadedb . \
    --namespace default \
    --values values.yaml \
    --wait \
    --timeout 10m

echo "Starting port-forward to svc/arcadedb-http on localhost:2480 ..."
kubectl port-forward svc/arcadedb-http 2480:2480 &
echo $! > "${PID_FILE}"
sleep 2
if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "ERROR: port-forward failed to start — port 2480 may already be in use"
    exit 1
fi

wait_for_ready

echo ""
echo "Cluster status:"
curl -sf -u "${ARCADEDB_USER}:${ARCADEDB_PASS}" "${ARCADEDB_URL}/api/v1/server" | jq .

echo ""
echo "Kubernetes HA cluster is up and ready."
