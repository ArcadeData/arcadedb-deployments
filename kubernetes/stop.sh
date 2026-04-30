#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

KIND_CLUSTER="${KIND_CLUSTER:-arcadedb}"
PID_FILE=".port-forward.pid"

# Kill background port-forward
if [ -f "${PID_FILE}" ]; then
    PID=$(cat "${PID_FILE}")
    if kill -0 "${PID}" 2>/dev/null; then
        echo "Stopping port-forward (PID ${PID}) ..."
        kill "${PID}"
    fi
    rm -f "${PID_FILE}"
fi

# Uninstall helm release
if helm status arcadedb --namespace default > /dev/null 2>&1; then
    echo "Uninstalling Helm release 'arcadedb' ..."
    helm uninstall arcadedb --namespace default
fi

# Delete kind cluster
echo "Deleting kind cluster '${KIND_CLUSTER}' ..."
kind delete cluster --name "${KIND_CLUSTER}"

echo "Done."
