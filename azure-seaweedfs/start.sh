#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

KIND_CLUSTER="${KIND_CLUSTER:-arcadedb-azure}"

# Create kind cluster if not already running
if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER}"; then
    echo "Kind cluster '${KIND_CLUSTER}' already exists, reusing."
else
    echo "Creating kind cluster '${KIND_CLUSTER}' ..."
    kind create cluster --name "${KIND_CLUSTER}"
fi

echo "Updating Helm dependencies ..."
helm dependency update .

echo "Installing the scenario Helm chart ..."
helm upgrade --install arcadedb . \
    --namespace default \
    --values values.yaml \
    --wait \
    --timeout 10m

./remote-setup.sh

echo ""
echo "SeaweedFS and floci-az are up."
