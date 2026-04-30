# Kubernetes Scenario — Design Spec

**Date:** 2026-04-30
**Status:** Approved

---

## Purpose

Add a `kubernetes/` scenario to the arcadedb-deployments showcase that demonstrates deploying a 3-node ArcadeDB HA cluster on Kubernetes using the official Helm chart. Follows the same script-driven pattern as `ha-cluster/` (`start.sh`, `stop.sh`, `test.sh`, `README.md`) and includes a CI workflow that runs on GitHub Actions using `kind`.

---

## Architecture

A wrapper Helm chart in `kubernetes/` declares a dependency on the published `arcadedb 26.4.2` chart from `https://helm.arcadedb.com`. The upstream chart deploys a 3-replica StatefulSet with HA already enabled: it sets `server.name` to `${HOSTNAME}` (the pod name, e.g. `arcadedb-0`), and constructs the `ha.serverList` from pod FQDNs using the headless service DNS suffix. The `ha.k8s=true` flag tells ArcadeDB to use k8s-style peer discovery.

A headless ClusterIP service handles intra-cluster Raft traffic. A second ClusterIP service (overriding the chart default of `LoadBalancer`, which does not work in kind without extras) is the HTTP entry point for tests, exposed locally via a background `kubectl port-forward`.

---

## File Layout

```
kubernetes/
├── Chart.yaml          # wrapper chart — dependency on arcadedb 26.4.2 @ helm.arcadedb.com
├── values.yaml         # overrides: replicaCount=3, service.http.type=ClusterIP, image.tag=26.4.2
├── charts/             # populated by helm dep update — gitignored
├── start.sh            # create kind cluster → helm install → wait → port-forward
├── stop.sh             # kill port-forward → helm uninstall → kind delete cluster
├── test.sh             # write record, read back, assert 3 HA nodes in cluster status
└── README.md
```

`.github/workflows/kubernetes.yml` triggers on changes to `kubernetes/**` or its own workflow file.

---

## `Chart.yaml`

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

---

## `values.yaml`

Overrides for the showcase (minimal — only what differs from chart defaults):

```yaml
replicaCount: 3

image:
  tag: "26.4.2"

service:
  http:
    type: ClusterIP   # LoadBalancer has no effect in kind without MetalLB

arcadedb:
  extraCommands:
    - -Darcadedb.server.mode=development
```

---

## `start.sh` Flow

1. `kind create cluster --name arcadedb` (skip if cluster already exists)
2. `helm dependency update kubernetes/`
3. `helm install arcadedb kubernetes/ --namespace default --wait --timeout 3m`
4. Start background `kubectl port-forward svc/arcadedb-http 2480:2480 &` and save PID to `kubernetes/.port-forward.pid`
5. Poll `/api/v1/ready` until healthy (max 90 attempts, 2s apart)
6. Print cluster status from `/api/v1/server`

Environment variables (with defaults):
- `ARCADEDB_USER=root`
- `ARCADEDB_PASS=arcadedb`
- `ARCADEDB_URL=http://localhost:2480`
- `KIND_CLUSTER=arcadedb`

---

## `stop.sh` Flow

1. Kill the background port-forward using the PID in `.port-forward.pid` (if the file exists)
2. `helm uninstall arcadedb --namespace default` (if release exists)
3. `kind delete cluster --name arcadedb`
4. Remove `.port-forward.pid`

Same env-var defaults as `start.sh` for the cluster name.

---

## `test.sh` Flow

1. Create a uniquely-named test database on the service endpoint
2. Create a `Message` document type, insert a record (`text = 'hello-k8s'`)
3. Read back the record with a retry loop (up to 15 attempts, 2s apart) and assert value matches
4. Call `/api/v1/server`, parse the HA node list with `jq`, assert exactly 3 nodes are `ONLINE`
5. Drop the test database in an `EXIT` trap
6. Print `PASS` (exit 0) or `FAIL` (exit 1) with pass/fail counts

Same env-var defaults as `start.sh`.

---

## CI Workflow — `kubernetes.yml`

```
on:
  push:
    paths: [kubernetes/**, .github/workflows/kubernetes.yml]
  pull_request:
    paths: [same]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 20        # longer than ha-cluster due to kind startup + image pull
    steps:
      - actions/checkout (pinned SHA)
      - Install kind (pinned version)
      - Install helm (pinned version)
      - ./kubernetes/start.sh
      - ./kubernetes/test.sh
      - kind delete cluster --name arcadedb   # if: always()
```

No `stop.sh` in CI — `kind delete cluster` directly is sufficient and avoids the PID file mechanism.

---

## `.gitignore` Addition

```gitignore
kubernetes/charts/
kubernetes/.port-forward.pid
```

---

## `README.md` Structure

- What this demonstrates (Helm-based HA cluster on Kubernetes, 3-node Raft)
- Prerequisites (Docker, kind, helm, kubectl, curl, jq)
- Quick Start (`./start.sh`, `./test.sh`, `./stop.sh`)
- Configuration table (replicaCount, image.tag, service type)
- Notes on port-forward approach and why LoadBalancer is not used with kind

---

## Conventions

Consistent with existing scenarios:
- `set -euo pipefail` in all scripts
- Env vars with defaults at the top of each script
- `curl` for ArcadeDB HTTP API calls
- `jq` for JSON parsing
- Pinned versions for all external tools in CI (kind, helm, action SHAs)
- Image tag and chart version pinned to `26.4.2`
