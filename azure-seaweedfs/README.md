# ArcadeDB HA Cluster on SeaweedFS + Azure Blob

A 3-node ArcadeDB Raft cluster on a local Kubernetes cluster (kind) whose database **and** Raft log directories live on [SeaweedFS](https://github.com/seaweedfs/seaweedfs), which tiers every file to Azure Blob Storage. Azure is emulated locally by [floci-az](https://github.com/floci-io/floci-az), so no Azure account is needed.

This prototypes **option A** of [ArcadeDB discussion #10616](https://github.com/ArcadeData/arcadedb/discussions/10616): ArcadeDB runs unchanged on a POSIX layer that stores its files in object storage.

## What This Demonstrates

- ArcadeDB, unmodified and unprivileged, running its databases and Raft log on a SeaweedFS FUSE mount provided by the SeaweedFS CSI driver
- SeaweedFS Cloud Drive (`remote.mount` + `filer.remote.sync`) writing every ArcadeDB file through to an Azure Blob container
- Leader failover on that storage
- Rebuilding the whole cluster from Blob alone, after every piece of SeaweedFS state has been deleted

## Architecture

```
kind cluster "arcadedb-azure" (namespace default)
├── floci-az               Azure Blob emulator, container "arcadedb"
├── seaweedfs              master, volume server, filer        (official chart)
│   └── filer: remote.mount /buckets/arcadedb ← Blob container "arcadedb"
├── seaweedfs-remote-sync  weed filer.remote.sync: filer changes → Blob
├── seaweedfs-csi-driver   FUSE mounts for the ArcadeDB pods   (official chart)
└── arcadedb               StatefulSet, 3 replicas, Raft HA    (official chart)
    └── per replica: /home/arcadedb/databases → /buckets/arcadedb/arcadedb-N/data
                     Raft storage directory   → /buckets/arcadedb/arcadedb-N/raft
```

Write path: ArcadeDB writes a page → CSI FUSE mount → SeaweedFS filer and volume server (durable here on `fsync`) → `filer.remote.sync` uploads it asynchronously → Blob.

Read path after a rebuild: the filer knows the file only from the Blob listing; the first read makes the volume server download it from Blob and cache it.

## Prerequisites

- Docker >= 24.0
- [kind](https://kind.sigs.k8s.io/) >= 0.24.0
- [Helm](https://helm.sh/) >= 3.16
- `kubectl`
- `curl` and `jq`

## Quick Start

```bash
# Start everything (kind cluster, floci-az, SeaweedFS, remote mount, ArcadeDB, port-forward)
./start.sh

# Verify (takes several minutes: it waits for Blob to catch up after each step)
./test.sh

# Tear down
./stop.sh
```

## What `test.sh` Proves

1. **Remote sync works:** a file written to the filer appears in Blob with the same content.
2. **Write and read through HA:** creates a database, inserts a record, reads it back, sees 3 nodes.
3. **ArcadeDB files are in Blob:** waits until Blob mirrors the filer (remote sync has handled every file's latest change, every file is there with the same size, nothing is left over from deleted files), then checks each replica's database files and Raft log.
4. **Leader failover:** deletes the leader pod; a new leader is elected, the record is still readable, and the third node rejoins.
5. **Cold restart from Blob alone:** scales ArcadeDB to 0, waits until Blob has everything the shutdown wrote, deletes every SeaweedFS pod (all their state is on `emptyDir`), the CSI mount service and remote sync, checks the filer is empty, mounts the Blob container again, and scales ArcadeDB back to 3. The cluster elects a leader, the record is read back, and a new write reaches Blob.

## Caveats

- **Remote sync is asynchronous.** `fsync` returns once SeaweedFS has the data, not once it is in Blob. Losing SeaweedFS before sync catches up loses the most recent writes from Blob. This is the main open question for option A. `test.sh` waits for sync before it destroys anything, so it tests the happy path, not this window.
- **Whole-file uploads.** Remote sync re-uploads a whole file on every change, so the Raft log segment and the WAL files are uploaded again and again. Blob trails the filer by seconds to minutes under write load.
- **Empty files never reach Blob.** Remote sync skips 0-byte files. ArcadeDB's only one is the `database.lck` lock file, which it recreates on open.
- **Three Blob copies of every database**, one per replica. Raft keeps the replicas consistent; SeaweedFS only stores what each node writes. This differs from the single-copy-per-tenant model in the discussion.
- **Not covered:** benchmarks or latency numbers, single-writer fencing or Blob leases, serverless or scale-to-zero, options B and C of the discussion, and real Azure.

## Emulator Notes

- SeaweedFS only accepts an `https` Azure endpoint. floci-az runs with TLS and a self-signed certificate it generates at startup. The filer, the volume server and remote sync each download that certificate in an init container and trust it through `SSL_CERT_DIR`. If the floci-az pod restarts, its certificate and all its data are gone; run `./stop.sh && ./start.sh`.
- floci-az runs with HTTP/2 disabled (`QUARKUS_HTTP_HTTP2=false`). Over HTTP/2, uploading a block of a large, frequently rewritten file stalled until the client cancelled it, and the stuck connection blocked every later request, so remote sync never caught up.
- The filer and volume server run with `allowUntrustedRemoteEndpoints`, because SeaweedFS refuses to talk to a private cluster IP otherwise. Against real Azure this is not needed.

## Inspecting Blob

```bash
kubectl port-forward svc/floci-az 4577:4577 &
curl -s "http://localhost:4577/devstoreaccount1/arcadedb?restype=container&comp=list" \
    | tr '<' '\n' | grep '^Name>' | cut -d'>' -f2
```

floci-az does not validate signatures, so no SAS token is needed.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCADEDB_USER` | `root` | ArcadeDB username |
| `ARCADEDB_PASS` | `arcadedb` | ArcadeDB password |
| `ARCADEDB_URL` | `http://localhost:2480` | ArcadeDB HTTP endpoint (via port-forward) |
| `KIND_CLUSTER` | `arcadedb-azure` | kind cluster name |
| `SYNC_TIMEOUT_SECONDS` | `600` | How long `test.sh` waits for Blob to catch up |

## How It Works

`start.sh` installs in two phases. SeaweedFS refuses to mount the Blob container over a non-empty directory, and the ArcadeDB volume mounts would create their directories first. So it installs floci-az and SeaweedFS with ArcadeDB disabled, runs `remote-setup.sh` (create the container, `remote.configure`, `remote.mount`, create the replica directories), then enables ArcadeDB.

Each replica's two directories are static PersistentVolumes pinned to fixed paths under `/buckets/arcadedb` (`templates/volumes.yaml`), so the files land in Blob under readable names and are found again at the same paths after a rebuild.

`remote-setup.sh` is safe to run again; `test.sh` runs it after wiping SeaweedFS.

## Notes

- `./stop.sh` kills the port-forward, uninstalls the Helm release, and deletes the kind cluster.
- The root password is `arcadedb` and the Blob account key is the well-known Azurite development key — change both for anything but a local demo.
- Keep `remoteSync.image` in `values.yaml` at the same version as the `seaweedfs` chart's appVersion when Dependabot bumps the chart.
- `azure-seaweedfs/charts/` is gitignored and populated by `helm dependency update`.
