# Azure SeaweedFS Scenario — Design Spec

**Date:** 2026-10-23
**Status:** Approved

---

## Purpose

Add an `azure-seaweedfs/` scenario that prototypes **option A** from
[ArcadeDB discussion #10616](https://github.com/ArcadeData/arcadedb/discussions/10616):
ArcadeDB runs **unchanged** on a POSIX layer (SeaweedFS) that tiers its files to
object storage, with **Azure Blob Storage** as the target cloud. The cloud is
simulated locally with [floci-az](https://github.com/floci-io/floci-az), so the
scenario runs on a laptop and in GitHub Actions with no Azure account.

It is a **runnable showcase**, like the other scenarios: `start.sh`, `stop.sh`,
`test.sh`, `README.md`, plus a CI workflow. It is not the benchmark harness the
discussion asks for (open time, cold-query latency, commit latency); those
measurements are out of scope here.

### What success looks like

- One command brings up a 3-node ArcadeDB Raft HA cluster on kind whose
  database **and** Raft log directories live on SeaweedFS.
- `test.sh` proves the data really reaches the (emulated) Azure Blob container
  and that the cluster survives losing its pods and the SeaweedFS local cache.
- The README states plainly what this does and does not prove for option A.

### Non-goals

- Benchmarks or latency numbers.
- Serverless / scale-to-zero (Azure Functions, Container Apps), even though
  floci-az emulates them.
- Single-writer fencing, Blob leases, multi-tenant database-per-tenant model.
- Options B and C of the discussion.
- Real Azure: no Terraform, no `az` against a real subscription.

### Anti-goals

- Any change to ArcadeDB itself or a fork of the arcadedb Helm chart. The whole
  point of option A is that ArcadeDB is unaware of the storage layer.
- Privileged ArcadeDB pods. FUSE privileges belong to the CSI driver only.
- Hiding the async-sync caveat (see Constraints). A showcase that implies
  "fsync = durable in Blob" would mislead the discussion.

---

## Approaches considered

1. **One wrapper Helm chart; SeaweedFS mounted through its CSI driver** —
   *chosen.* A single `helm install` into kind deploys SeaweedFS (official
   chart), the SeaweedFS CSI driver (official chart), floci-az (small templates
   in the wrapper chart) and ArcadeDB (official chart). ArcadeDB pods stay
   unprivileged and see ordinary PVCs. Mirrors the `kubernetes/` scenario.
   Trade-off: three upstream charts whose versions must stay aligned.
2. **`weed mount` sidecar in each ArcadeDB pod** — rejected: ArcadeDB pods must
   run privileged with `/dev/fuse`; less like a real deployment.
3. **SeaweedFS + floci-az in Docker Compose, only ArcadeDB in kind** — rejected:
   two orchestrators, cross-network plumbing between kind and Compose, messier CI.

---

## Architecture

```
kind cluster (namespace default)
├── floci-az            Deployment + Service :4577  (Blob Storage emulator)
├── seaweedfs           master, volume, filer        (official chart)
│   └── filer: remote.configure → floci-az Blob
│              remote.mount /buckets/arcadedb ← blob container "arcadedb"
│              weed filer.remote.sync (continuous write-back to Blob)
├── seaweedfs-csi-driver  StorageClass "seaweedfs"   (official chart)
└── arcadedb            StatefulSet, 3 replicas, Raft HA (official chart)
    └── per replica: PVC arcadedb-data  (seaweedfs) → /home/arcadedb/databases
                     PVC arcadedb-raft  (seaweedfs) → Raft storage directory
```

Data path: ArcadeDB writes a page → CSI FUSE mount → SeaweedFS filer/volume
servers (durable here on `fsync`) → `filer.remote.sync` uploads asynchronously
→ floci-az Blob container `arcadedb`.

Each replica has its own PVCs, so Blob holds **three copies** of every database
and Raft log (one per replica). Raft keeps the replicas consistent; SeaweedFS
only provides durable storage beneath each node. The README calls this out
because it differs from the discussion's single-copy-per-tenant model.

### Decisions taken in the conversation

- Orchestration: **kind + Helm**, same pattern as `kubernetes/`.
- Cloud target: **Azure Blob**, emulated by **floci-az**.
- Topology: **3-node Raft HA**.
- **Both** `databases/` and the Raft log live on SeaweedFS (the honest test of
  option A, since the Raft log is the most fsync-sensitive file).
- Approach 1 above.

---

## Components

### floci-az

- Image `floci/floci-az` (pin a released tag, e.g. 0.15.0 or later; Dependabot
  can track it via the `docker` ecosystem only if referenced from a Dockerfile —
  otherwise pin in values and bump manually; builder's call).
- No Docker socket mount (Functions not used).
- Account name/key: any value works (SharedKey not validated). Use the Azurite
  well-known `devstoreaccount1` style values so they read as obviously fake.
- Rendered by templates in the wrapper chart (`templates/floci-az.yaml`), since
  floci-az has no Helm chart. Blob container `arcadedb` created by a Helm hook
  Job or by `start.sh` (builder's call).

### SeaweedFS

- Official chart from `https://seaweedfs.github.io/seaweedfs/helm`, single
  master, single volume server, single filer (showcase sizing).
- Remote storage configured against floci-az with
  `remote.configure -type=azure -azure.account_name=... -azure.account_key=...
  -azure.endpoint=http://floci-az:4577/<account>` (flag verified in SeaweedFS
  source; exact URL shape floci-az expects is for the builder to confirm).
  If floci-az's Blob API turns out not to support a call SeaweedFS makes
  (block staging/commit, prefix listing), stop and report back before choosing
  a workaround. `remote.configure` + `remote.mount` run once after the
  filer is ready (Helm post-install hook Job or `start.sh` via `weed shell`;
  builder's call).
- `weed filer.remote.sync` runs as a long-lived process (its own Deployment or a
  filer sidecar; builder's call) so changes keep flowing to Blob.

### SeaweedFS CSI driver

- Official chart from `https://seaweedfs.github.io/seaweedfs-csi-driver/helm`,
  `seaweedfsFiler` pointing at the filer Service.
- Provides StorageClass `seaweedfs`. PVC directories must land under the
  remote-mounted path (`/buckets/arcadedb/...`) so they are synced to Blob;
  how to achieve that (StorageClass parameters such as a path/collection
  prefix, or mounting the remote at the CSI root) is for the builder to verify.

### ArcadeDB

- Official chart from `https://helm.arcadedb.com`, unchanged, 3 replicas,
  `service.http.type: ClusterIP`, `image.tag` **not** set (chart defaults it to
  its appVersion; pinning lets them drift — see `kubernetes/values.yaml`).
- The chart mounts every reserved directory on `emptyDir` by default;
  `persistence.storageClass` does **not** govern the data directory. Override
  `volumes` to drop `arcadedb-data` and `arcadedb-raft`, and declare matching
  `volumeClaimTemplates` with `storageClassName: seaweedfs`.
- Root password via the same pre-created secret as `kubernetes/start.sh`.

---

## File layout

```
azure-seaweedfs/
├── Chart.yaml           # wrapper: deps arcadedb, seaweedfs, seaweedfs-csi-driver
├── Chart.lock
├── values.yaml
├── templates/           # floci-az Deployment/Service, setup Job(s), remote.sync
├── start.sh             # kind create → helm dep update → secret → helm install --wait → port-forward
├── stop.sh              # kill port-forward → helm uninstall → kind delete
├── test.sh
└── README.md
```

Plus `.github/workflows/azure-seaweedfs.yml` (copy of `kubernetes.yml` shape,
paths `azure-seaweedfs/**`, debug step also dumps seaweedfs/floci-az logs),
an entry in `all-modules.yml`, a `helm` Dependabot entry for `/azure-seaweedfs`,
and a row in the root `README.md` scenarios table.

kind cluster name: `arcadedb-azure`, so it can coexist with `kubernetes/`.
Port-forward: `localhost:2480` as in `kubernetes/` (both scenarios can't run at
once; acceptable).

---

## `test.sh`

Same helper style as `kubernetes/test.sh` (`check`, PASS/FAIL counts, retries).

1. **Write/read through HA:** create database, type, insert a record; read it
   back; assert 3 HA nodes online.
2. **Data is in Blob:** after waiting for `filer.remote.sync` to catch up, list
   the floci-az `arcadedb` container (REST call from a throwaway pod or via
   port-forward) and assert blobs exist for each replica's database files and
   Raft log.
3. **Leader failover:** delete the leader pod; assert a new leader is elected,
   the record is readable, and 3 nodes come back.
4. **Cold restart from Blob alone:** scale ArcadeDB to 0, then wipe SeaweedFS
   entirely — uninstall it (or delete its pods and every PVC holding filer
   metadata and volume data) so nothing survives but the floci-az container.
   Reinstall SeaweedFS, re-run `remote.configure` + `remote.mount` (and
   `remote.meta.sync` if needed) to rebuild the metadata from Blob, scale
   ArcadeDB back to 3; assert the cluster forms, a leader is elected and the
   record is still readable. This proves Blob alone is enough to rebuild the
   cluster, not just that file contents are re-fetched (`remote.uncache` alone
   was rejected as too weak). The one-time remote setup must therefore be
   re-runnable (idempotent script or re-triggerable Job), and the ArcadeDB PVCs
   must survive the SeaweedFS reinstall (the CSI volume handle must resolve to
   the same filer path after rebuild — builder to verify).

Steps 3 and 4 must wait long enough for remote sync before destroying anything,
otherwise the test exercises the async caveat instead of the happy path.

---

## Constraints and caveats (for the README)

- **`filer.remote.sync` is asynchronous.** `fsync` returns once SeaweedFS has the
  data, not once it is in Blob. Losing the filer before sync completes loses
  recent writes from Blob. This is the main open question for option A and the
  README must say so.
- FUSE: privileges live in the CSI node plugin; works on GitHub Actions
  `ubuntu-latest` and on Docker Desktop kind (to be confirmed by the builder).
- CI time budget: `kubernetes.yml` uses 20 min; this scenario pulls more images
  and should allow ~30 min.
- Three Blob copies per database (one per replica) — showcase trade-off.

---

## If ArcadeDB misbehaves on SeaweedFS

If ArcadeDB or its Raft log does not work correctly on the SeaweedFS mount
(file locking, fsync, preallocation, Raft log corruption after a pod kill, ...),
**stop and report back** with the evidence. Do not move the Raft log to local
disk, mark tests as expected-to-fail, or otherwise work around it: such a
failure is a finding for discussion #10616 and how to present it is the
author's decision.

---

## Left to the builder

- Exact chart versions (latest at build time) and value keys of the SeaweedFS
  and CSI charts.
- Hook Job vs. `start.sh` for one-time setup (container creation,
  `remote.configure`, `remote.mount`).
- Where `filer.remote.sync` runs.
- How to make CSI volumes land under the remote-mounted path.
- How `test.sh` lists blobs in floci-az.
