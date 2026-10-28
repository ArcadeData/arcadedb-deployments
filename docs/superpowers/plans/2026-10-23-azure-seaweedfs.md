# Azure SeaweedFS Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `azure-seaweedfs/` scenario: a 3-node ArcadeDB Raft HA cluster on kind whose database and Raft directories live on SeaweedFS, which syncs them to an emulated Azure Blob container (floci-az), and prove the cluster can be rebuilt from Blob alone.

**Architecture:** One wrapper Helm chart (release `arcadedb`) with three upstream dependencies — `seaweedfs`, `seaweedfs-csi-driver`, `arcadedb` — plus local templates for floci-az, the `filer.remote.sync` Deployment and six **static** PV/PVC pairs that pin each replica's `data` and `raft` directory to a fixed filer path under the remote-mounted `/buckets/arcadedb`. An idempotent `remote-setup.sh` runs `weed shell` to configure and mount the remote; it is used by `start.sh` and again by the cold-restart test.

**Tech Stack:** kind, Helm 3, bash, curl, jq, SeaweedFS (chart 4.49.x), SeaweedFS CSI driver, floci-az, ArcadeDB chart 26.9.1.

**Spec:** `docs/superpowers/specs/2026-10-23-azure-seaweedfs-design.md`

## Global Constraints

- Scenario directory `azure-seaweedfs/`; kind cluster `arcadedb-azure`; Helm release `arcadedb` in namespace `default`; HTTP port-forward `localhost:2480`.
- ArcadeDB chart and its pods are **unchanged and unprivileged**; never set `arcadedb.image.tag` (chart defaults it to appVersion).
- Pin every upstream chart version exactly in `Chart.yaml` (latest at build time); pin floci-az and helper images to exact tags, never `latest`.
- floci-az: account `devstoreaccount1`, key = Azurite well-known key `Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==`, Blob URL `http://floci-az:4577/devstoreaccount1`, container `arcadedb`. No Docker socket mount.
- SeaweedFS remote: name `floci`, mounted at filer dir `/buckets/arcadedb` from `floci/arcadedb`.
- Replica paths: `/buckets/arcadedb/arcadedb-<n>/data` → `/home/arcadedb/databases`, `/buckets/arcadedb/arcadedb-<n>/raft` → `/home/arcadedb/raft`, n ∈ {0,1,2}.
- Showcase style: readability over DRY, no YAML anchors, scripts mirror `kubernetes/` (`set -euo pipefail`, `cd "$(dirname "${BASH_SOURCE[0]}")"`, `check` helper, PASS/FAIL tally).
- **Stop rules (from spec):** if floci-az's Blob API rejects a call SeaweedFS needs, or ArcadeDB/Raft misbehaves on the SeaweedFS mount (locking, fsync, preallocation, corruption after pod kill), **stop and report back with evidence**. No workarounds (no Raft on local disk, no expected-fail tests, no switching emulator or remote type).

## Review Focus

1. **Async sync race:** a test destroys pods before `filer.remote.sync` has uploaded the latest writes → spurious data loss. Every destructive test step must first call `wait_for_remote_sync` (Task 2), which passes only when every regular file under `/buckets/arcadedb` on the filer has a blob of the same name and size.
2. **FUSE ownership:** ArcadeDB runs as uid/gid 1000 with `fsGroup: 1000`; a FUSE mount owned by root makes the server fail at startup with permission errors. Task 2's 3-nodes-online check catches it; if it fails for this reason, fix it in the PV `volumeAttributes`/CSI mount options, not in the ArcadeDB pods.
3. **Re-running `start.sh`** on an existing cluster (kind cluster reused, release already installed) must not error or double-mount: `remote-setup.sh` is idempotent (Task 1 test runs it twice).
4. **Empty directories after rebuild:** Blob has no directories, so an empty `raft/` or `data/` path is gone after the SeaweedFS wipe; `remote-setup.sh` recreates all six paths after mounting (Task 4 asserts the cluster forms).
5. **Port 2480 already in use** (e.g. `kubernetes/` scenario still running): `start.sh` must fail with the same clear message as `kubernetes/start.sh`.

---

## File Structure

```
azure-seaweedfs/
├── Chart.yaml                 # wrapper chart + 3 dependencies
├── values.yaml                # overrides for seaweedfs, seaweedfs-csi-driver, arcadedb
├── templates/
│   ├── floci-az.yaml          # Deployment + Service :4577
│   ├── remote-sync.yaml       # Deployment running weed filer.remote.sync
│   └── volumes.yaml           # 6 static PVs + 6 PVCs named as the StatefulSet expects
├── remote-setup.sh            # idempotent: container, remote.configure, remote.mount, mkdirs
├── start.sh
├── stop.sh
├── test.sh
└── README.md
.github/workflows/azure-seaweedfs.yml
.github/workflows/all-modules.yml       # add job
.github/dependabot.yml                  # add helm entry
.gitignore / azure-seaweedfs/.gitignore # charts/, .port-forward.pid (match kubernetes/)
README.md                               # scenarios table row + prerequisites
```

Shared names used across tasks (verify the SeaweedFS service names after setting `fullnameOverride: seaweedfs`; adjust everywhere if the chart names them differently):

| Thing | Name |
|---|---|
| Filer service | `seaweedfs-filer:8888` |
| Master service | `seaweedfs-master:9333` |
| floci-az service | `floci-az:4577` |
| StorageClass for static PVs | `""` (none) — PVCs bind via `volumeName` |
| PV names | `arcadedb-data-arcadedb-<n>-pv`, `arcadedb-raft-arcadedb-<n>-pv` |
| PVC names | `arcadedb-data-arcadedb-<n>`, `arcadedb-raft-arcadedb-<n>` (StatefulSet adopts them) |
| Helper image | `curlimages/curl` pinned tag, used via `kubectl run --rm -i --restart=Never` |

---

### Task 1: floci-az + SeaweedFS + remote mount and sync

The riskiest piece; it gates everything else.

**Files:**
- Create: `azure-seaweedfs/Chart.yaml` (deps: `seaweedfs` from `https://seaweedfs.github.io/seaweedfs/helm` only, for now), `values.yaml`, `templates/floci-az.yaml`, `templates/remote-sync.yaml`, `remote-setup.sh`, `start.sh`, `stop.sh`, `test.sh`, `.gitignore`

**Interfaces:**
- Produces: `remote-setup.sh` (no args; env `KIND_CLUSTER` unused; exits 0 when the remote is configured, mounted at `/buckets/arcadedb`, and the six replica directories exist). In `test.sh`: `blob_list` → prints blob names one per line from `GET http://floci-az:4577/devstoreaccount1/arcadedb?restype=container&comp=list`; `filer_put <path> <content>`; `wait_for_remote_sync` (rule in Review Focus 1, timeout 120 s, returns 1 on timeout).

- [ ] **Step 1: Write `test.sh` section "Remote sync"**: put `/buckets/arcadedb/_canary/hello.txt` with content `hello-azure` via the filer HTTP API; `wait_for_remote_sync`; `check "canary blob in floci-az" "$(blob_list | grep -c '^_canary/hello.txt$')" "1"`; then download the blob and `check "canary content" "<body>" "hello-azure"`; delete the canary afterwards. All HTTP calls to in-cluster services go through the pinned curl pod.
- [ ] **Step 2: Write `start.sh`/`stop.sh`** modelled on `kubernetes/` (kind cluster `arcadedb-azure`, `helm dependency update`, `helm install arcadedb . --wait`) and run `./start.sh && ./test.sh`. Expected: FAIL — nothing configures the remote yet.
- [ ] **Step 3: Implement** `values.yaml` for SeaweedFS (`fullnameOverride: seaweedfs`, 1 master, 1 volume, 1 filer, all data on `emptyDir` so deleting pods wipes them — Task 4 relies on this), `templates/floci-az.yaml` (pinned image, readiness on TCP 4577), `templates/remote-sync.yaml` (SeaweedFS image matching the chart's appVersion, `weed filer.remote.sync -filer=seaweedfs-filer:8888 -dir=/buckets/arcadedb`, restarts until the mount exists), and `remote-setup.sh`: create container `arcadedb` if absent; pipe into `weed shell` (via `kubectl exec` on the filer pod) `remote.configure -name=floci -type=azure -azure.account_name=devstoreaccount1 -azure.account_key=<key> -azure.endpoint=http://floci-az:4577/devstoreaccount1` and, only if `remote.mount` (no args) does not list `/buckets/arcadedb`, `remote.mount -dir=/buckets/arcadedb -remote=floci/arcadedb`; then create the six replica directories. `start.sh` calls it after `helm install`.
- [ ] **Step 4: Run** `./start.sh && ./remote-setup.sh && ./test.sh`. Expected: PASS for both checks, and the second `remote-setup.sh` exits 0 without a second mount. If SeaweedFS→floci-az calls fail, **stop and report** (stop rule).
- [ ] **Step 5: Commit** `feat(azure-seaweedfs): floci-az blob remote for SeaweedFS`.

---

### Task 2: ArcadeDB 3-node HA on SeaweedFS via CSI

**Files:**
- Modify: `azure-seaweedfs/Chart.yaml` (add `seaweedfs-csi-driver` from `https://seaweedfs.github.io/seaweedfs-csi-driver/helm`, `arcadedb 26.9.1` from `https://helm.arcadedb.com`), `values.yaml`, `start.sh`, `test.sh`
- Create: `azure-seaweedfs/templates/volumes.yaml`

**Interfaces:**
- Consumes: `remote-setup.sh`, `blob_list`, `wait_for_remote_sync` (Task 1).
- Produces in `test.sh`: `command_on`, `query_on`, `wait_for_database`, `query_with_retry`, `ha_wait_for_nodes` (same signatures as `kubernetes/test.sh`); `leader_pod` → prints the pod name of the current Raft leader from `/api/v1/server?mode=cluster`.

- [ ] **Step 1: Extend `test.sh`** with sections ported from `kubernetes/test.sh`: create db `azure_test_$$`, type `Message`, insert `text='hello-azure'`, `check "record readable from cluster"`, `check "3 HA nodes online"`. Add "ArcadeDB files in Blob": `wait_for_remote_sync`, then for each n in 0..2 `check "replica <n> database files in Blob"` (≥1 blob under `arcadedb-<n>/data/azure_test_$$/`) and `check "replica <n> raft log in Blob"` (≥1 blob under `arcadedb-<n>/raft/`).
- [ ] **Step 2: Run** `./test.sh` against the Task 1 deployment. Expected: FAIL (no ArcadeDB).
- [ ] **Step 3: Implement.** `values.yaml`: CSI `seaweedfsFiler: seaweedfs-filer:8888`; arcadedb `replicaCount: 3`, `service.http.type: ClusterIP`, credentials secret as in `kubernetes/values.yaml`, `-Darcadedb.server.mode=development`, `volumes` = chart default minus `arcadedb-data` and `arcadedb-raft`, `volumeClaimTemplates` for both names with `storageClassName: ""`, `ReadWriteOnce`, `1Gi`. `templates/volumes.yaml`: for n in 0..2 and each of data/raft, a PV (`csi.driver: seaweedfs-csi-driver`, `volumeHandle` = PV name, `volumeAttributes.path` = the Global Constraints path, `persistentVolumeReclaimPolicy: Retain`, `claimRef` to the PVC) and the matching PVC with `volumeName`. `start.sh`: install **without** `--wait`, wait for SeaweedFS rollouts, run `remote-setup.sh`, then `kubectl rollout status statefulset/arcadedb --timeout=10m`, then port-forward and readiness exactly as `kubernetes/start.sh` (including the port-in-use error).
- [ ] **Step 4: Run** `./stop.sh; ./start.sh && ./test.sh`. Expected: all checks PASS. If ArcadeDB fails on the mount for anything other than ownership (Review Focus 2), **stop and report** with pod logs.
- [ ] **Step 5: Commit** `feat(azure-seaweedfs): 3-node ArcadeDB HA with data and raft on SeaweedFS`.

---

### Task 3: Leader failover

**Files:** Modify: `azure-seaweedfs/test.sh`

**Interfaces:** Consumes `leader_pod`, `ha_wait_for_nodes`, `query_with_retry`, `wait_for_remote_sync`.

- [ ] **Step 1: Add section "Leader failover"**: `wait_for_remote_sync`; `OLD=$(leader_pod)`; `kubectl delete pod "$OLD"`; wait (≤120 s) until `leader_pod` returns a non-empty name ≠ `$OLD` → `check "new leader elected" ...`; `check "record survives failover" "$(query_with_retry hello-azure)" "hello-azure"`; `check "3 HA nodes online after failover" "$(ha_wait_for_nodes 3)" "3"`. Restart the port-forward if the deleted pod was behind it (helper `restart_port_forward`, same PID file as `start.sh`).
- [ ] **Step 2: Run** `./test.sh`. Expected: PASS. A Raft log error after the pod kill is a stop-rule event.
- [ ] **Step 3: Commit** `test(azure-seaweedfs): leader failover`.

---

### Task 4: Cold restart from Blob alone

**Files:** Modify: `azure-seaweedfs/test.sh`

**Interfaces:** Consumes `remote-setup.sh`, `wait_for_remote_sync`, `leader_pod`, `query_with_retry`, `ha_wait_for_nodes`, `restart_port_forward`.

- [ ] **Step 1: Add section "Cold restart from Blob"**: `wait_for_remote_sync`; record `BLOBS_BEFORE=$(blob_list | wc -l)`; `kubectl scale statefulset arcadedb --replicas=0` and wait for 0 pods; delete every SeaweedFS pod and the remote-sync pod (emptyDir → all filer metadata and volume data gone); `check "filer is empty after wipe"` (listing `/buckets/` returns no `arcadedb` entry once the filer is back up); run `./remote-setup.sh`; scale to 3 and `kubectl rollout status`; `restart_port_forward`; `check "leader elected after cold restart"` (non-empty `leader_pod`); `check "3 HA nodes online after cold restart" ... "3"`; `check "record restored from Blob" "$(query_with_retry hello-azure)" "hello-azure"`; then insert `text='after-restore'`, `wait_for_remote_sync`, `check "writes sync to Blob after restore"` (blob count > `BLOBS_BEFORE` or modified data blob).
- [ ] **Step 2: Run** `./test.sh`. Expected: PASS. If ArcadeDB cannot open the restored files or Raft refuses the restored log, **stop and report**.
- [ ] **Step 3: Run** the full cycle `./stop.sh; ./start.sh && ./test.sh` once more. Expected: PASS, proving the test leaves nothing behind that breaks a fresh run.
- [ ] **Step 4: Commit** `test(azure-seaweedfs): rebuild cluster from Blob alone`.

---

### Task 5: CI, Dependabot, docs

**Files:**
- Create: `.github/workflows/azure-seaweedfs.yml`, `azure-seaweedfs/README.md`
- Modify: `.github/workflows/all-modules.yml`, `.github/dependabot.yml`, `README.md`

- [ ] **Step 1: Workflow** — copy `kubernetes.yml`: name `Azure SeaweedFS CI`, paths `azure-seaweedfs/**` and its own file, `timeout-minutes: 30`, same pinned kind/Helm install steps, run `./azure-seaweedfs/start.sh` then `./azure-seaweedfs/test.sh`; debug step on failure dumps pods, PV/PVC status, and logs of `arcadedb-{0,1,2}`, the filer, the remote-sync Deployment and floci-az; teardown `kind delete cluster --name arcadedb-azure`. Add the job to `all-modules.yml` the same way the other modules are added; add a `helm` Dependabot entry for `/azure-seaweedfs` mirroring the `/kubernetes` one.
- [ ] **Step 2: Docs** — root README: table row `[Azure SeaweedFS](./azure-seaweedfs/) | 3-node HA cluster on SeaweedFS, tiered to (emulated) Azure Blob via floci-az | Kubernetes / Helm`. Scenario README: link to discussion #10616 (option A); architecture diagram from the spec; how to run; what `test.sh` proves; **caveats verbatim in substance from the spec**: `filer.remote.sync` is asynchronous (fsync durable in SeaweedFS, not yet in Blob; losing the filer before sync loses recent writes), three Blob copies per database (one per replica), no benchmarks/fencing/serverless; how to inspect blobs (`kubectl port-forward svc/floci-az 4577` + list URL).
- [ ] **Step 3: Verify** `actionlint .github/workflows/azure-seaweedfs.yml` (or `pre-commit run --all-files` if configured) passes, then push the branch and confirm the `Azure SeaweedFS CI` run is green.
- [ ] **Step 4: Commit** `ci(azure-seaweedfs): workflow, dependabot and docs`.
