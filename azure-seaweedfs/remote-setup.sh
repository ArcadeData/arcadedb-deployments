#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Connects SeaweedFS to the (emulated) Azure Blob container. Safe to run more
# than once: start.sh runs it on install, test.sh runs it again after wiping
# SeaweedFS, when the mount rebuilds the filer metadata from Blob.

ACCOUNT_NAME="devstoreaccount1"
ACCOUNT_KEY="Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
# floci-az serves HTTP and HTTPS on one port. SeaweedFS insists on HTTPS.
BLOB_URL="https://floci-az:4577/${ACCOUNT_NAME}"
BLOB_HTTP_URL="http://floci-az:4577/${ACCOUNT_NAME}"
CONTAINER="arcadedb"
REMOTE_NAME="floci"
MOUNT_DIR="/buckets/arcadedb"
FILER_POD="seaweedfs-filer-0"

weed_shell() {
    kubectl exec -i "${FILER_POD}" -c seaweedfs -- \
        weed shell -master=seaweedfs-master:9333 -filer=seaweedfs-filer:8888
}

echo "Creating Blob container '${CONTAINER}' (ignored if it exists) ..."
kubectl exec "${FILER_POD}" -c seaweedfs -- curl -sS -X PUT \
    "${BLOB_HTTP_URL}/${CONTAINER}?restype=container" > /dev/null

echo "Configuring remote storage '${REMOTE_NAME}' ..."
echo "remote.configure -name=${REMOTE_NAME} -type=azure \
    -azure.account_name=${ACCOUNT_NAME} -azure.account_key=${ACCOUNT_KEY} \
    -azure.endpoint=${BLOB_URL}" | weed_shell

if echo "remote.mount" | weed_shell | grep -q "\"${MOUNT_DIR}\""; then
    echo "${MOUNT_DIR} is already mounted."
else
    echo "Mounting ${REMOTE_NAME}/${CONTAINER} at ${MOUNT_DIR} ..."
    echo "remote.mount -dir=${MOUNT_DIR} -remote=${REMOTE_NAME}/${CONTAINER}" | weed_shell
fi

# Check the mount itself before creating anything under it: a directory
# created while nothing is mounted would make every later remote.mount refuse
# the now non-empty directory.
if ! echo "remote.mount" | weed_shell | grep -q "\"${MOUNT_DIR}\""; then
    echo "ERROR: ${MOUNT_DIR} is not mounted; see the remote.configure / remote.mount output above"
    exit 1
fi

# Blob has no directories, so an empty replica directory does not survive a
# rebuild from Blob. Create all of them on every run; fs.mkdir is a no-op when
# the directory exists.
echo "Creating replica directories ..."
for n in 0 1 2; do
    echo "fs.mkdir ${MOUNT_DIR}/arcadedb-${n}/data" | weed_shell > /dev/null
    echo "fs.mkdir ${MOUNT_DIR}/arcadedb-${n}/raft" | weed_shell > /dev/null
done

echo "Mounted remotes:"
echo "remote.mount" | weed_shell
