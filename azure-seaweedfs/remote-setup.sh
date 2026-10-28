#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Connects SeaweedFS to the (emulated) Azure Blob container. Safe to run more
# than once: start.sh runs it on install, test.sh runs it again after wiping
# SeaweedFS, when the mount rebuilds the filer metadata from Blob.

ACCOUNT_NAME="devstoreaccount1"
ACCOUNT_KEY="Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="
# SeaweedFS insists on HTTPS; Azurite serves it with a self-signed certificate
# that the filer pod keeps in /azurite-ca.
BLOB_URL="https://azurite:10000/${ACCOUNT_NAME}"
CA_FILE="/azurite-ca/azurite.crt"
CONTAINER="arcadedb"
REMOTE_NAME="azurite"
MOUNT_DIR="/buckets/arcadedb"
FILER_POD="seaweedfs-filer-0"

weed_shell() {
    kubectl exec -i "${FILER_POD}" -- \
        weed shell -master=seaweedfs-master:9333 -filer=seaweedfs-filer:8888
}

# Azurite checks every request's signature. An account SAS token signed with
# the account key authorizes plain curl calls without the SharedKey headers.
account_sas() {
    local hex_key signature
    local params="sv=2019-12-12&ss=b&srt=sco&sp=rwdlac&se=2099-12-31T00:00:00Z&spr=https"
    hex_key=$(printf '%s' "${ACCOUNT_KEY}" | base64 -d | od -An -v -tx1 | tr -d ' \n')
    signature=$(printf '%s\nrwdlac\nb\nsco\n\n2099-12-31T00:00:00Z\n\nhttps\n2019-12-12\n' "${ACCOUNT_NAME}" \
        | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${hex_key}" -binary \
        | base64 | sed 's/+/%2B/g; s|/|%2F|g; s/=/%3D/g')
    echo "${params}&sig=${signature}"
}

echo "Creating Blob container '${CONTAINER}' (ignored if it exists) ..."
kubectl exec "${FILER_POD}" -- curl -sS --cacert "${CA_FILE}" -X PUT \
    "${BLOB_URL}/${CONTAINER}?restype=container&$(account_sas)" > /dev/null

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
