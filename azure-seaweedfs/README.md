# ArcadeDB HA Cluster on SeaweedFS + Azure Blob

A 3-node ArcadeDB Raft cluster on a local Kubernetes cluster (kind). Its database **and** Raft log directories live on [SeaweedFS](https://github.com/seaweedfs/seaweedfs), which tiers every file to Azure Blob Storage. Azure is emulated locally by [floci-az](https://github.com/floci-io/floci-az), so no Azure account is needed.

This prototypes **option A** of [ArcadeDB discussion #10616](https://github.com/ArcadeData/arcadedb/discussions/10616): ArcadeDB runs unchanged on a POSIX layer that keeps its files in object storage.

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

**Write path:** ArcadeDB writes a page → CSI FUSE mount → SeaweedFS filer and volume server (durable here on `fsync`) → `filer.remote.sync` uploads the file asynchronously → Blob.

**Read path after a rebuild:** the filer knows a file only from the Blob listing. The first read makes the volume server download it from Blob and cache it.

## Prerequisites

- Docker >= 24.0
- [kind](https://kind.sigs.k8s.io/) >= 0.24.0
- [Helm](https://helm.sh/) >= 3.16
- `kubectl`
- `curl` and `jq`

## Quick Start

```bash
# Start everything: kind cluster, floci-az, SeaweedFS, remote mount, ArcadeDB, port-forward (about 5 minutes)
./start.sh

# Verify (about 5 to 10 minutes: it waits for Blob to catch up before each check that depends on it)
./test.sh

# Tear down
./stop.sh
```

All three scripts act on the `kind-arcadedb-azure` context only. The [kubernetes](../kubernetes/) scenario installs a release with the same name in the same namespace, so the two clusters can exist side by side, but they cannot both use port 2480 at once.

## What `test.sh` Proves

1. **Remote sync works:** a file written to the filer appears in Blob with the same content.
2. **Write and read through HA:** creates a database, inserts a record, reads it back, sees 3 nodes.
3. **ArcadeDB files are in Blob:** waits until Blob mirrors the filer, then checks each replica's database files and Raft log. "Mirrors" means three things:
   - remote sync has handled every file's latest change;
   - every file is in Blob with the same size;
   - nothing is left over from a file the filer has deleted.
4. **Leader failover:** deletes the leader pod. A new leader is elected, the record is still readable, and the deleted pod comes back and rejoins.
5. **Cold restart from Blob alone:**
   1. Scales ArcadeDB to 0 and waits until Blob holds everything the shutdown wrote.
   2. Deletes every SeaweedFS pod (all their state is on `emptyDir`), the CSI mount service and remote sync, and checks that the filer is empty. Blob is now the only copy.
   3. Mounts the Blob container again and scales ArcadeDB back to 3.
   4. Checks that a leader is elected, the record is read back, and a new write reaches Blob.

   If Blob has not caught up after the shutdown, the test fails and skips the wipe, instead of rebuilding from a stale copy.

After `test.sh`, the port-forward on `localhost:2480` points at the `arcadedb-0` pod rather than the Service, because the test has to move it during failover. Run `./start.sh` again to restore the Service port-forward.

## Caveats

- **Remote sync is asynchronous.** `fsync` returns once SeaweedFS has the data, not once it is in Blob. Losing SeaweedFS before sync catches up loses the most recent writes from Blob. This is the main open question for option A. `test.sh` waits for sync before it destroys anything, so it tests the happy path, not this window.
- **Whole-file uploads.** Remote sync re-uploads a whole file on every change, so the Raft log segment and the WAL files are uploaded again and again. Blob trails the filer by seconds to minutes under write load.
- **Empty files never reach Blob.** Remote sync skips 0-byte files. ArcadeDB's only one is the `database.lck` lock file, which it recreates on open.
- **Three Blob copies of every database**, one per replica. Raft keeps the replicas consistent; SeaweedFS only stores what each node writes. This differs from the single-copy-per-tenant model in the discussion.
- **Not covered:** benchmarks or latency numbers, single-writer fencing or Blob leases, serverless or scale-to-zero, options B and C of the discussion, and real Azure.

## Findings

What building this taught us about option A:

- **SeaweedFS 4.48 lost rename events.** ArcadeDB and Ratis replace small files atomically (write `x.tmp`, rename it over `x`), and `filer.remote.sync` failed on those renames, so Blob kept stale content. Fixed in SeaweedFS 4.49 and later; this scenario uses 4.51.
- **Blob timestamps do not show whether Blob is current.** At shutdown, ArcadeDB rewrites `statistics.json` with identical content. Remote sync sees that the content is unchanged and does not upload it, so the copy in Blob looks older than the file. To decide whether Blob has caught up, `test.sh` uses the filer's own record of the last sync (`last_local_sync_ts_ns`), not Blob's last-modified time.
- **The volume server downloads Blob-only files.** After a rebuild, reads are served by the volume server, so it needs network access to the Blob endpoint (and, here, the emulator's certificate), not just the filer.
- **Open:** two CI runs during development saw a deleted `txlog_0.wal` remain in Blob after a 10-minute wait. It has not happened since. The CI workflow keeps 1000 lines of the remote sync log on failure so that a repeat can be traced.

## Emulator Notes

- **TLS:** SeaweedFS only accepts an `https` Azure endpoint, so floci-az runs with TLS and a self-signed certificate it generates at startup. The filer, the volume server and remote sync each download that certificate in an init container and trust it through `SSL_CERT_DIR`. If the floci-az pod restarts, its certificate and all its data are gone; run `./stop.sh && ./start.sh`.
- **HTTP/1.1 only:** floci-az runs with HTTP/2 disabled (`QUARKUS_HTTP_HTTP2=false`). Over HTTP/2, uploading a block of a large, frequently rewritten file stalled until the client cancelled it, and the stuck connection blocked every later request, so remote sync never caught up.
- **Private endpoint:** the filer and volume server run with `allowUntrustedRemoteEndpoints`, because otherwise SeaweedFS refuses to talk to a private cluster IP. Against real Azure this is not needed.

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

`start.sh` installs in two phases. SeaweedFS refuses to mount the Blob container over a non-empty directory, and the ArcadeDB volume mounts would create their directories first. So it:

1. installs floci-az and SeaweedFS with ArcadeDB disabled;
2. runs `remote-setup.sh`, which creates the Blob container, runs `remote.configure` and `remote.mount`, checks that the mount is there, and creates the replica directories;
3. enables ArcadeDB.

Each replica's two directories are static PersistentVolumes pinned to fixed paths under `/buckets/arcadedb` (`templates/volumes.yaml`). The files land in Blob under readable names, and a rebuild finds them again at the same paths.

`start.sh` and `remote-setup.sh` are safe to run again on a running cluster; `test.sh` runs `remote-setup.sh` after wiping SeaweedFS.

## Notes

- `./stop.sh` kills the port-forward and deletes the kind cluster, which removes everything in it.
- The root password is `arcadedb` and the Blob account key is the well-known Azurite development key. Change both for anything but a local demo.
- Keep `remoteSync.image` in `values.yaml` at the same version as the `seaweedfs` chart's appVersion when Dependabot bumps the chart.
- `azure-seaweedfs/charts/` is gitignored and populated by `helm dependency update`.
