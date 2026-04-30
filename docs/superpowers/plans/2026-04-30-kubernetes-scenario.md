# Kubernetes Scenario Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `kubernetes/` scenario that deploys a 3-node ArcadeDB HA cluster on Kubernetes via Helm, with `start.sh`, `stop.sh`, `test.sh`, and a GitHub Actions CI workflow using `kind`.

**Architecture:** A wrapper Helm chart in `kubernetes/` pulls the published `arcadedb 26.4.2` chart from `https://helm.arcadedb.com` and overrides `replicaCount=3`, `image.tag=26.4.2`, and `service.http.type=ClusterIP`. `start.sh` creates a `kind` cluster, installs the chart, then opens a background `kubectl port-forward`. `test.sh` writes a record through the service, reads it back, and asserts 3 HA nodes are online via the `/api/v1/server` endpoint.

**Tech Stack:** Helm 3, kind, kubectl, Bash, GitHub Actions, ArcadeDB 26.4.2 Helm chart from helm.arcadedb.com

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Create | `kubernetes/Chart.yaml` | Wrapper chart declaring dependency on arcadedb 26.4.2 |
| Create | `kubernetes/values.yaml` | Overrides: replicaCount=3, ClusterIP, image tag |
| Create | `kubernetes/start.sh` | Create kind cluster, helm install, port-forward |
| Create | `kubernetes/stop.sh` | Kill port-forward, helm uninstall, kind delete |
| Create | `kubernetes/test.sh` | Write + read record, assert 3 HA nodes online |
| Create | `kubernetes/README.md` | Scenario docs |
| Create | `.github/workflows/kubernetes.yml` | CI: kind + helm setup, run start/test/teardown |
| Modify | `.gitignore` | Add `kubernetes/charts/` and `kubernetes/.port-forward.pid` |
| Modify | `.github/dependabot.yml` | Add helm ecosystem for `kubernetes/` |
| Modify | `README.md` | Add Kubernetes row to scenario table, add k8s prerequisites |

---

## Task 1: Wrapper chart config files

**Files:**
- Create: `kubernetes/Chart.yaml`
- Create: `kubernetes/values.yaml`

- [ ] **Step 1: Create `kubernetes/Chart.yaml`**

```yaml
apiVersion: v2
name: arcadedb-kubernetes
description: Wrapper chart for the ArcadeDB Kubernetes showcase scenario
type: application
version: 0.1.0
dependencies:
  - name: arcadedb
    version: "26.4.2"
    repository: https://helm.arcadedb.com
```

- [ ] **Step 2: Create `kubernetes/values.yaml`**

All keys are nested under `arcadedb:` because this is a wrapper chart — Helm namespaces sub-chart values under the dependency name.

```yaml
arcadedb:
  replicaCount: 3

  image:
    tag: "26.4.2"

  service:
    http:
      type: ClusterIP   # LoadBalancer is a no-op in kind without MetalLB
```

- [ ] **Step 3: Run `helm dependency update` to verify the chart resolves**

Prerequisites: `helm` must be installed locally. If not: `brew install helm`.

```bash
cd kubernetes/
helm dependency update .
```

Expected output:
```
Saving 1 charts
Downloading arcadedb from repo https://helm.arcadedb.com
Deleting outdated charts
```

A `charts/arcadedb-26.4.2.tgz` file appears under `kubernetes/charts/`.

- [ ] **Step 4: Run `helm template` to verify the rendered manifests look correct**

```bash
helm template arcadedb . -f values.yaml | grep -E 'kind:|replicas:|image:|type:'
```

Expected to see `StatefulSet`, `replicas: 3`, `arcadedata/arcadedb:26.4.2`, and `ClusterIP`.

- [ ] **Step 5: Commit**

```bash
cd ..   # back to repo root
git add kubernetes/Chart.yaml kubernetes/values.yaml
git commit -m "feat(kubernetes): add wrapper helm chart config"
```

---

## Task 2: `start.sh`

**Files:**
- Create: `kubernetes/start.sh`

- [ ] **Step 1: Create `kubernetes/start.sh`**

```bash
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

echo "Installing ArcadeDB Helm chart (3 replicas, this may take a few minutes) ..."
helm install arcadedb . \
    --namespace default \
    --values values.yaml \
    --wait \
    --timeout 3m

echo "Starting port-forward to svc/arcadedb-http on localhost:2480 ..."
kubectl port-forward svc/arcadedb-http 2480:2480 &
echo $! > "${PID_FILE}"

wait_for_ready

echo ""
echo "Cluster status:"
curl -sf -u "${ARCADEDB_USER}:${ARCADEDB_PASS}" "${ARCADEDB_URL}/api/v1/server" | jq .

echo ""
echo "Kubernetes HA cluster is up and ready."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x kubernetes/start.sh
```

- [ ] **Step 3: Run `start.sh` locally to verify it works end-to-end**

Prerequisites: `kind`, `helm`, `kubectl`, `curl`, `jq` installed locally.

```bash
./kubernetes/start.sh
```

Expected: kind cluster created, 3 ArcadeDB pods become ready (this takes 2–3 minutes for image pull + Raft formation), port-forward starts, cluster status JSON printed showing 3 nodes.

If pods stay in `Pending` state, check: `kubectl get pods` and `kubectl describe pod arcadedb-0`.

If Raft doesn't form (pods crash-loop), check logs: `kubectl logs arcadedb-0`.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/start.sh
git commit -m "feat(kubernetes): add start.sh"
```

---

## Task 3: `stop.sh`

**Files:**
- Create: `kubernetes/stop.sh`

- [ ] **Step 1: Create `kubernetes/stop.sh`**

```bash
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
```

- [ ] **Step 2: Make executable**

```bash
chmod +x kubernetes/stop.sh
```

- [ ] **Step 3: Run `stop.sh` to verify it tears down the cluster from Task 2**

```bash
./kubernetes/stop.sh
```

Expected: port-forward killed, helm release removed, kind cluster deleted. Running `kind get clusters` afterward should return empty.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/stop.sh
git commit -m "feat(kubernetes): add stop.sh"
```

---

## Task 4: `test.sh`

**Files:**
- Create: `kubernetes/test.sh`

- [ ] **Step 1: Start the cluster (needed to write and verify the test)**

```bash
./kubernetes/start.sh
```

- [ ] **Step 2: Check the actual `/api/v1/server` response to confirm HA field names**

```bash
curl -sf -u root:arcadedb http://localhost:2480/api/v1/server | jq '{ha}'
```

The response will show the HA structure. Confirm that `.ha.servers` is the array field and `.status` is the field containing `"ONLINE"`. If the field names differ (e.g., `.ha.nodes`), adjust the `jq` expression in Step 3 accordingly.

- [ ] **Step 3: Create `kubernetes/test.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
ARCADEDB_URL="${ARCADEDB_URL:-http://localhost:2480}"
DB="k8s_test_$$"
PASS_COUNT=0
FAIL_COUNT=0

command_on() {
    local sql="$1"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$ARCADEDB_URL/api/v1/command/$DB"
}

query_on() {
    local sql="$1"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$ARCADEDB_URL/api/v1/query/$DB"
}

check() {
    local desc="$1"
    local result="$2"
    local expected="$3"
    if [ "$result" = "$expected" ]; then
        echo "  PASS: $desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo "  FAIL: $desc"
        echo "        expected: $expected"
        echo "        got:      $result"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

cleanup() {
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "{\"command\":\"drop database $DB\"}" \
        "$ARCADEDB_URL/api/v1/server" > /dev/null 2>&1 || true
}
trap cleanup EXIT

query_with_retry() {
    local expected="$1"
    local result attempt
    for attempt in $(seq 1 15); do
        result="$(query_on "select text from Message" 2>/dev/null \
            | jq -r '.result[0].text // empty' 2>/dev/null)" || result=""
        [ "$result" = "$expected" ] && { echo "$result"; return 0; }
        sleep 2
    done
    echo "${result:-}"
    return 1
}

echo "=== ArcadeDB Kubernetes HA Cluster Test ==="
echo ""

echo "Creating test database ..."
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"create database $DB\"}" \
    "$ARCADEDB_URL/api/v1/server" > /dev/null

command_on "create document type Message" > /dev/null
command_on "insert into Message set text = 'hello-k8s'" > /dev/null

echo "Reading record back ..."
RESULT="$(query_with_retry "hello-k8s")" || RESULT=""
check "record readable from cluster" "$RESULT" "hello-k8s"

echo "Checking HA cluster has 3 online nodes ..."
ONLINE_NODES=$(curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    "$ARCADEDB_URL/api/v1/server" \
    | jq '[.ha.servers[] | select(.status == "ONLINE")] | length' 2>/dev/null) \
    || ONLINE_NODES=0
check "3 HA nodes online" "$ONLINE_NODES" "3"

echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
```

- [ ] **Step 4: Make executable**

```bash
chmod +x kubernetes/test.sh
```

- [ ] **Step 5: Run `test.sh` against the live cluster**

```bash
./kubernetes/test.sh
```

Expected output:
```
=== ArcadeDB Kubernetes HA Cluster Test ===

Creating test database ...
Reading record back ...
  PASS: record readable from cluster
Checking HA cluster has 3 online nodes ...
  PASS: 3 HA nodes online

Results: 2 passed, 0 failed

PASS
```

If the HA node count check fails (ONLINE_NODES=0), the `.ha.servers` field name is wrong. Recheck the API response from Task 4 Step 2 and update the `jq` expression.

- [ ] **Step 6: Stop the cluster**

```bash
./kubernetes/stop.sh
```

- [ ] **Step 7: Commit**

```bash
git add kubernetes/test.sh
git commit -m "feat(kubernetes): add test.sh"
```

---

## Task 5: `README.md`

**Files:**
- Create: `kubernetes/README.md`

- [ ] **Step 1: Create `kubernetes/README.md`**

```markdown
# ArcadeDB 3-Node HA Cluster on Kubernetes

A 3-node ArcadeDB cluster deployed via Helm onto a local Kubernetes cluster (kind), using Raft consensus for high availability.

## What This Demonstrates

- Helm-based deployment using the official ArcadeDB chart
- ArcadeDB HA mode with Raft-based leader election across 3 StatefulSet pods
- Kubernetes-native peer discovery via headless service DNS

## Prerequisites

- Docker >= 24.0
- [kind](https://kind.sigs.k8s.io/) >= 0.24.0
- [Helm](https://helm.sh/) >= 3.16
- `kubectl`
- `curl` and `jq`

## Quick Start

```bash
# Start the cluster (creates a kind cluster, installs the Helm chart, starts port-forward)
./start.sh

# Verify the cluster is working
./test.sh

# Tear down
./stop.sh
```

## Configuration

| Parameter | Value | Description |
|-----------|-------|-------------|
| `arcadedb.replicaCount` | `3` | Number of ArcadeDB pods |
| `arcadedb.image.tag` | `26.4.2` | ArcadeDB image version |
| `arcadedb.service.http.type` | `ClusterIP` | Service type (LoadBalancer not used with kind) |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCADEDB_USER` | `root` | ArcadeDB username |
| `ARCADEDB_PASS` | `arcadedb` | ArcadeDB password |
| `ARCADEDB_URL` | `http://localhost:2480` | ArcadeDB HTTP endpoint (via port-forward) |
| `KIND_CLUSTER` | `arcadedb` | kind cluster name |

## How It Works

`start.sh` creates a kind cluster, runs `helm dependency update` + `helm install --wait`, then opens a background `kubectl port-forward svc/arcadedb-http 2480:2480`. The port-forward PID is stored in `.port-forward.pid` so `stop.sh` can clean it up.

The Helm chart uses a StatefulSet: pod names are `arcadedb-0`, `arcadedb-1`, `arcadedb-2`. ArcadeDB sets `server.name` to `${HOSTNAME}` and discovers peers via the headless service DNS (`arcadedb-0.arcadedb.default.svc.cluster.local`, etc.).

`LoadBalancer` service type is not used because kind does not support it without MetalLB. ClusterIP with port-forward is the standard approach for local kind clusters.

## Notes

- `./stop.sh` kills the port-forward, uninstalls the Helm release, and deletes the kind cluster.
- The root password is `arcadedb` — change it for any non-local deployment.
- `kubernetes/charts/` is gitignored and populated by `helm dependency update`.
```

- [ ] **Step 2: Commit**

```bash
git add kubernetes/README.md
git commit -m "docs(kubernetes): add README"
```

---

## Task 6: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/kubernetes.yml`

- [ ] **Step 1: Create `.github/workflows/kubernetes.yml`**

`timeout-minutes: 20` — kind startup + ArcadeDB image pull + Raft formation takes longer than ha-cluster's Docker Compose startup.

```yaml
name: Kubernetes CI

on:
  push:
    paths:
      - kubernetes/**
      - .github/workflows/kubernetes.yml
  pull_request:
    paths:
      - kubernetes/**
      - .github/workflows/kubernetes.yml

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
        with:
          fetch-depth: 1

      - name: Install kind
        run: |
          curl -sLo /usr/local/bin/kind \
            https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
          chmod +x /usr/local/bin/kind
          kind version

      - name: Install Helm
        run: |
          curl -sSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz \
            | tar xz -C /tmp
          sudo mv /tmp/linux-amd64/helm /usr/local/bin/helm
          helm version

      - name: Start Kubernetes cluster
        run: ./kubernetes/start.sh

      - name: Test Kubernetes cluster
        run: ./kubernetes/test.sh

      - name: Tear down
        if: always()
        run: kind delete cluster --name arcadedb
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/kubernetes.yml
git commit -m "ci: add kubernetes workflow"
```

---

## Task 7: Repository config (gitignore, dependabot, root README)

**Files:**
- Modify: `.gitignore`
- Modify: `.github/dependabot.yml`
- Modify: `README.md`

- [ ] **Step 1: Add k8s entries to `.gitignore`**

Append to `.gitignore`:

```gitignore
# Kubernetes scenario
kubernetes/charts/
kubernetes/.port-forward.pid
```

- [ ] **Step 2: Add helm ecosystem to `.github/dependabot.yml`**

Current content of `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/ha-cluster"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"
```

Add the helm entry at the end:

```yaml
version: 2
updates:
  - package-ecosystem: "docker"
    directory: "/ha-cluster"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"

  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"

  - package-ecosystem: "helm"
    directory: "/kubernetes"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"
```

- [ ] **Step 3: Update root `README.md`**

Current content of `README.md`:

```markdown
# ArcadeDB Deployment Scenarios

A collection of ready-to-run deployment configurations for ArcadeDB,
from single-node development setups to production-grade HA clusters.

## Scenarios

| Scenario | Description | Orchestrator |
|----------|-------------|--------------|
| [HA Cluster](./ha-cluster/) | 3-node high-availability cluster with Raft consensus | Docker Compose |

## Prerequisites

- Docker >= 24.0
- Docker Compose >= 2.0
- `curl` and `jq`

## Quick Start

Each scenario directory contains:
- `start.sh` — bring the deployment up
- `test.sh` — verify the deployment is working
- `README.md` — scenario-specific details and configuration options
```

Replace with:

```markdown
# ArcadeDB Deployment Scenarios

A collection of ready-to-run deployment configurations for ArcadeDB,
from single-node development setups to production-grade HA clusters.

## Scenarios

| Scenario | Description | Orchestrator |
|----------|-------------|--------------|
| [HA Cluster](./ha-cluster/) | 3-node high-availability cluster with Raft consensus | Docker Compose |
| [Kubernetes](./kubernetes/) | 3-node HA cluster deployed via Helm on a local kind cluster | Kubernetes / Helm |

## Prerequisites

- Docker >= 24.0
- Docker Compose >= 2.0 (ha-cluster scenario)
- [kind](https://kind.sigs.k8s.io/) >= 0.24.0, [Helm](https://helm.sh/) >= 3.16, `kubectl` (kubernetes scenario)
- `curl` and `jq`

## Quick Start

Each scenario directory contains:
- `start.sh` — bring the deployment up
- `stop.sh` — tear the deployment down (kubernetes scenario)
- `test.sh` — verify the deployment is working
- `README.md` — scenario-specific details and configuration options
```

- [ ] **Step 4: Commit**

```bash
git add .gitignore .github/dependabot.yml README.md
git commit -m "chore: add kubernetes scenario to gitignore, dependabot, and root README"
```

---

## Self-Review

**Spec coverage:**
- [x] Wrapper chart with dependency on arcadedb 26.4.2 @ helm.arcadedb.com → Task 1
- [x] values.yaml: replicaCount=3, ClusterIP, image.tag=26.4.2 → Task 1
- [x] start.sh: kind → helm install → port-forward → poll ready → status → Task 2
- [x] stop.sh: kill port-forward → helm uninstall → kind delete → Task 3
- [x] test.sh: write + read + assert 3 online nodes → Task 4
- [x] kubernetes/README.md → Task 5
- [x] CI workflow with kind + helm, timeout-minutes: 20 → Task 6
- [x] .gitignore entries → Task 7
- [x] dependabot.yml helm ecosystem → Task 7
- [x] Root README updated → Task 7

**Placeholder scan:** No TBDs, TODOs, or vague steps. Step 2 of Task 4 explicitly instructs the developer to verify the HA API field names against the live API before trusting the jq expression.

**Type consistency:** `ARCADEDB_URL`, `ARCADEDB_USER`, `ARCADEDB_PASS`, `KIND_CLUSTER`, `PID_FILE` env vars and local variable names are consistent across start.sh, stop.sh, test.sh. The service name `arcadedb-http` matches what the upstream chart generates for release name `arcadedb` (release name contains chart name → fullname is `arcadedb` → HTTP service is `arcadedb-http`).
