# ArcadeDB Deployments — Design Spec

**Date:** 2026-04-29
**Status:** Approved

---

## Purpose

This repository showcases ready-to-run deployment configurations for ArcadeDB. Each scenario lives in its own directory and can be started and verified with two shell scripts. The root README is a navigable index; per-scenario READMEs contain the details. The goal is to demonstrate deployment patterns, not to replace the deep integration tests in the main ArcadeDB repository.

---

## Repository Layout

```
arcadedb-deployments/
├── README.md                        # Scenario index
├── .github/
│   ├── workflows/
│   │   ├── single-node.yml
│   │   ├── ha-cluster.yml
│   │   └── kubernetes.yml
│   └── dependabot.yml
├── .mergify.yml                     # Auto-merge dependabot PRs
├── .pre-commit-config.yaml          # shfmt, yaml, detect-secrets
├── single-node/
│   ├── README.md
│   ├── docker-compose.yml
│   ├── start.sh
│   └── test.sh
├── ha-cluster/
│   ├── README.md
│   ├── docker-compose.yml
│   ├── start.sh
│   └── test.sh
└── kubernetes/
    ├── README.md
    ├── Chart.yaml                   # wrapper chart — enables Dependabot tracking
    ├── values.yaml
    ├── start.sh
    └── test.sh
```

---

## Planned Scenarios

| Directory | Description | Orchestrator |
|-----------|-------------|--------------|
| `single-node/` | Minimal single-node setup for development and evaluation | Docker Compose |
| `ha-cluster/` | 3-node high-availability cluster with Raft consensus | Docker Compose |
| `kubernetes/` | Production Helm-based deployment | Kubernetes / Helm |

---

## Per-Scenario Structure

Every scenario contains exactly four files (plus `README.md`):

### `start.sh`

Brings the deployment up and waits for it to be healthy.

```
set -euo pipefail
ARCADEDB_URL defaults to http://localhost:2480 (env-overridable)
ARCADEDB_USER defaults to root
ARCADEDB_PASS defaults to arcadedb
Poll /api/v1/ready until the node(s) report healthy
Print a status summary
```

### `test.sh`

Verifies the deployment is working. Scope is intentionally narrow — cluster formation and basic read/write, not exhaustive correctness testing.

```
For single-node: write one record, read it back, assert match
For ha-cluster:  write via node 1, read back via node 2 and node 3, assert all agree
For kubernetes:  write via the Helm-deployed service, read it back
Print PASS or FAIL with a short reason on failure
Exit 0 on pass, non-zero on failure
```

### `docker-compose.yml` (docker-compose scenarios)

- Uses the official `arcadedata/arcadedb` image with a pinned version tag
- Root password via `JAVA_OPTS: "-Darcadedb.server.rootPassword=arcadedb"` (env var form does not work in current releases)
- Healthcheck: `curl -sf http://localhost:2480/api/v1/ready`, interval 5s, 20 retries

### `Chart.yaml` + `values.yaml` (kubernetes scenario)

- `Chart.yaml` declares a Helm dependency on the official ArcadeDB chart from `https://github.com/ArcadeData/arcadedb/tree/main/k8s/helm`
- `values.yaml` contains only the overrides needed for the showcase (replica count, resource limits, ingress)
- Pinned chart version in `Chart.yaml` so Dependabot can track and bump it

---

## HA Cluster Specifics

Three ArcadeDB nodes on a shared Docker network. Key configuration:

- Each node has a unique `arcadedb.server.name`
- `arcadedb.ha.serverList` lists all three nodes by hostname and port
- Ports exposed: node1 → 2480 (primary entry point), node2 → 2481, node3 → 2482
- `start.sh` polls `/api/v1/ready` on all three ports before reporting healthy
- `test.sh` creates a database on node1, inserts a record, reads it from node2 and node3

---

## Root README Structure

```markdown
# ArcadeDB Deployment Scenarios

A collection of ready-to-run deployment configurations for ArcadeDB,
from single-node development setups to production-grade HA clusters.

## Scenarios

| Scenario       | Description                                              | Orchestrator          |
|----------------|----------------------------------------------------------|-----------------------|
| Single Node    | Minimal setup for development and evaluation             | Docker Compose        |
| HA Cluster     | 3-node high-availability cluster with Raft consensus     | Docker Compose        |
| Kubernetes     | Production Helm-based deployment                         | Kubernetes / Helm     |

## Prerequisites

- Docker + Docker Compose (for docker-compose scenarios)
- kubectl + Helm 3 + kind (for Kubernetes scenario)

## Quick Start

Each scenario directory contains:
- `start.sh` — bring the deployment up
- `test.sh` — verify the deployment is working
- `README.md` — scenario-specific details and configuration options
```

---

## CI — GitHub Actions

One workflow file per scenario, triggered on push/PR to paths within that scenario's directory or its own workflow file.

**Common structure:**

```yaml
on:
  push:
    paths:
      - <scenario>/**
      - .github/workflows/<scenario>.yml
  pull_request:
    paths: [same]

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - actions/checkout (pinned SHA)
      - docker compose up -d        # or: helm install via kind cluster
      - ./<scenario>/start.sh
      - ./<scenario>/test.sh
      - docker compose down         # if: always()
```

No matrix strategy — each scenario has a single shell-based runner.

**Kubernetes workflow additions:**
- Install `kind` to create a local cluster in the runner
- Install `helm`
- `helm dependency update kubernetes/` before `helm install`
- Teardown: `kind delete cluster` (if: always())

All action versions are pinned to commit SHAs.

---

## Dependency Management

### Dependabot (`dependabot.yml`)

Three ecosystems:

```yaml
- package-ecosystem: docker          # arcadedb image tags in docker-compose files
  directories: [/single-node, /ha-cluster]

- package-ecosystem: github-actions  # pinned action SHAs in .github/workflows/

- package-ecosystem: helm            # chart dependency version in kubernetes/Chart.yaml
  directory: /kubernetes
```

### Mergify (`.mergify.yml`)

Auto-merge Dependabot PRs after one human approval, appending `[skip ci]` to the commit message. Identical to the arcadedb-usecases pattern.

---

## Pre-commit Hooks (`.pre-commit-config.yaml`)

Ported from arcadedb-usecases, scoped to what's relevant here:

- `shfmt` — shell script formatting (indent 4, compact)
- `pretty-format-yaml` — YAML formatting (indent 2)
- `detect-private-key`, `detect-aws-credentials` — secret scanning
- `check-xml`, `check-json` — structural validation
- `trailing-whitespace`, `mixed-line-ending` — general hygiene

---

## Conventions

| Aspect | Convention |
|--------|-----------|
| Shell scripts | `set -euo pipefail`; env vars with defaults; `curl` for ArcadeDB HTTP API |
| Image pinning | Explicit version tag (not `latest`) in docker-compose and Chart.yaml |
| Script exit codes | `test.sh` exits non-zero on any assertion failure |
| Commit style | `feat(<scenario>):`, `ci:`, `docs:`, `chore:` |
| Secret defaults | `root` / `arcadedb` — clearly documented as dev-only |
