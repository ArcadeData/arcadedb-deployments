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
