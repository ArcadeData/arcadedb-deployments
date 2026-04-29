# HA Cluster Deployment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the HA cluster deployment scenario and all shared repository infrastructure (root README, pre-commit, mergify, dependabot, CI workflow).

**Architecture:** Three ArcadeDB nodes run in a shared Docker Compose network with Raft consensus. `start.sh` issues `docker compose up -d` then polls `/api/v1/ready` on all three nodes. `test.sh` writes a record via node1 and reads it back via node2 and node3 to verify replication. CI runs both scripts on push/PR; Dependabot bumps the image version weekly.

**Tech Stack:** Docker Compose, ArcadeDB HA (Raft), Bash, GitHub Actions, Dependabot

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `README.md` | Modify | Root scenario index |
| `.mergify.yml` | Create | Auto-merge dependabot PRs |
| `.pre-commit-config.yaml` | Create | shfmt + YAML + secret scanning hooks |
| `.github/dependabot.yml` | Create | Track arcadedb image + GH action versions |
| `.github/workflows/ha-cluster.yml` | Create | CI: start → test → teardown |
| `ha-cluster/docker-compose.yml` | Create | 3-node ArcadeDB HA cluster definition |
| `ha-cluster/start.sh` | Create | Bring cluster up, wait for all 3 nodes healthy |
| `ha-cluster/test.sh` | Create | Write on node1, read from node2+node3, assert |
| `ha-cluster/README.md` | Create | Scenario-specific docs |

---

### Task 1: Repository infrastructure

**Files:**
- Modify: `README.md`
- Create: `.mergify.yml`
- Create: `.pre-commit-config.yaml`

- [ ] **Step 1: Update root README.md**

Replace the full content of `README.md` with:

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

- [ ] **Step 2: Create .mergify.yml**

```yaml
pull_request_rules:
  - name: Merge Dependabot PRs on approval with [skip ci]
    conditions:
      - "#approved-reviews-by>=1"
      - "author=dependabot[bot]"
    actions:
      merge:
        method: merge
        commit_message_template: "{{ title }} [skip ci]"
```

- [ ] **Step 3: Create .pre-commit-config.yaml**

Adapted from the usecases repo — Python, Java, XML, and Helm hooks removed; shfmt and pretty-format-yaml scoped to all files (not just `bindings/python/`):

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: fix-byte-order-marker
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: mixed-line-ending
      - id: detect-aws-credentials
        args:
          - --allow-missing-credentials
      - id: detect-private-key
      - id: check-case-conflict
      - id: check-yaml
        args:
          - --allow-multiple-documents
      - id: check-json
      - id: check-xml
  - repo: https://github.com/macisamuele/language-formatters-pre-commit-hooks
    rev: v2.15.0
    hooks:
      - id: pretty-format-yaml
        args:
          - --autofix
          - --indent=2
  - repo: https://github.com/scop/pre-commit-shfmt
    rev: v3.12.0-2
    hooks:
      - id: shfmt
        args: ["-i", "4", "-ci", "-sr", "-w"]
```

- [ ] **Step 4: Commit**

```bash
git add README.md .mergify.yml .pre-commit-config.yaml
git commit -m "chore: add repository infrastructure files"
```

---

### Task 2: HA cluster docker-compose

**Files:**
- Create: `ha-cluster/docker-compose.yml`

- [ ] **Step 1: Create ha-cluster/docker-compose.yml**

```yaml
services:
  node1:
    image: arcadedata/arcadedb:26.4.2
    environment:
      JAVA_OPTS: >-
        -Darcadedb.server.name=node1
        -Darcadedb.server.rootPassword=arcadedb
        -Darcadedb.ha.serverList=node1:2424,node2:2424,node3:2424
        -Darcadedb.ha.replicationFactor=3
    ports:
      - "2480:2480"
      - "2424:2424"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:2480/api/v1/ready"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks:
      - arcadedb-ha

  node2:
    image: arcadedata/arcadedb:26.4.2
    environment:
      JAVA_OPTS: >-
        -Darcadedb.server.name=node2
        -Darcadedb.server.rootPassword=arcadedb
        -Darcadedb.ha.serverList=node1:2424,node2:2424,node3:2424
        -Darcadedb.ha.replicationFactor=3
    ports:
      - "2481:2480"
      - "2425:2424"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:2480/api/v1/ready"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks:
      - arcadedb-ha

  node3:
    image: arcadedata/arcadedb:26.4.2
    environment:
      JAVA_OPTS: >-
        -Darcadedb.server.name=node3
        -Darcadedb.server.rootPassword=arcadedb
        -Darcadedb.ha.serverList=node1:2424,node2:2424,node3:2424
        -Darcadedb.ha.replicationFactor=3
    ports:
      - "2482:2480"
      - "2426:2424"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:2480/api/v1/ready"]
      interval: 5s
      timeout: 3s
      retries: 20
    networks:
      - arcadedb-ha

networks:
  arcadedb-ha:
    driver: bridge
```

- [ ] **Step 2: Validate**

```bash
docker compose -f ha-cluster/docker-compose.yml config
```

Expected: no errors, prints the resolved config.

- [ ] **Step 3: Commit**

```bash
git add ha-cluster/docker-compose.yml
git commit -m "feat(ha-cluster): add 3-node docker-compose configuration"
```

---

### Task 3: start.sh

**Files:**
- Create: `ha-cluster/start.sh`

- [ ] **Step 1: Create ha-cluster/start.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
NODE1_URL="${NODE1_URL:-http://localhost:2480}"
NODE2_URL="${NODE2_URL:-http://localhost:2481}"
NODE3_URL="${NODE3_URL:-http://localhost:2482}"
MAX_ATTEMPTS=60

wait_for_node() {
    local url="$1"
    local name="$2"
    local attempt=0
    echo "Waiting for $name at $url ..."
    while ! curl -sf "$url/api/v1/ready" > /dev/null 2>&1; do
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
            echo "ERROR: $name did not become ready after $MAX_ATTEMPTS attempts"
            exit 1
        fi
        sleep 2
    done
    echo "$name is ready"
}

echo "Starting ArcadeDB HA cluster (3 nodes) ..."
docker compose up -d

wait_for_node "$NODE1_URL" "node1"
wait_for_node "$NODE2_URL" "node2"
wait_for_node "$NODE3_URL" "node3"

echo ""
echo "Cluster status:"
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" "$NODE1_URL/api/v1/server" | jq .

echo ""
echo "HA cluster is up and ready."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x ha-cluster/start.sh
```

- [ ] **Step 3: Bring up and verify**

```bash
./ha-cluster/start.sh
```

Expected: script polls each node, prints `node1 is ready`, `node2 is ready`, `node3 is ready`, then prints the server JSON and `HA cluster is up and ready.` (takes ~30–60 s on first run while the image is pulled).

- [ ] **Step 4: Tear down**

```bash
docker compose -f ha-cluster/docker-compose.yml down -v
```

- [ ] **Step 5: Commit**

```bash
git add ha-cluster/start.sh
git commit -m "feat(ha-cluster): add start.sh to bring up cluster and wait for health"
```

---

### Task 4: test.sh

**Files:**
- Create: `ha-cluster/test.sh`

- [ ] **Step 1: Create ha-cluster/test.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ARCADEDB_USER="${ARCADEDB_USER:-root}"
ARCADEDB_PASS="${ARCADEDB_PASS:-arcadedb}"
NODE1_URL="${NODE1_URL:-http://localhost:2480}"
NODE2_URL="${NODE2_URL:-http://localhost:2481}"
NODE3_URL="${NODE3_URL:-http://localhost:2482}"
DB="ha_test_$$"
PASS_COUNT=0
FAIL_COUNT=0

command_on() {
    local url="$1"
    local sql="$2"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$url/api/v1/command/$DB"
}

query_on() {
    local url="$1"
    local sql="$2"
    local body
    body=$(jq -n --arg cmd "$sql" '{"language":"sql","command":$cmd}')
    curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "$url/api/v1/query/$DB"
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
        "$NODE1_URL/api/v1/server" > /dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=== ArcadeDB HA Cluster Test ==="
echo ""

echo "Creating test database on node1 ..."
curl -sf -u "$ARCADEDB_USER:$ARCADEDB_PASS" \
    -H "Content-Type: application/json" \
    -d "{\"command\":\"create database $DB\"}" \
    "$NODE1_URL/api/v1/server" > /dev/null

command_on "$NODE1_URL" "create document type Message" > /dev/null
command_on "$NODE1_URL" "insert into Message set text = 'hello-ha'" > /dev/null

echo "Waiting for replication ..."
sleep 2

echo "Reading from node2 ..."
RESULT2=$(query_on "$NODE2_URL" "select text from Message" | jq -r '.result[0].text')
check "record readable from node2" "$RESULT2" "hello-ha"

echo "Reading from node3 ..."
RESULT3=$(query_on "$NODE3_URL" "select text from Message" | jq -r '.result[0].text')
check "record readable from node3" "$RESULT3" "hello-ha"

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

- [ ] **Step 2: Make executable**

```bash
chmod +x ha-cluster/test.sh
```

- [ ] **Step 3: Bring up cluster and run test**

```bash
./ha-cluster/start.sh
./ha-cluster/test.sh
```

Expected output:
```
=== ArcadeDB HA Cluster Test ===

Creating test database on node1 ...
Waiting for replication ...
Reading from node2 ...
  PASS: record readable from node2
Reading from node3 ...
  PASS: record readable from node3

Results: 2 passed, 0 failed

PASS
```

- [ ] **Step 4: Tear down**

```bash
docker compose -f ha-cluster/docker-compose.yml down -v
```

- [ ] **Step 5: Commit**

```bash
git add ha-cluster/test.sh
git commit -m "feat(ha-cluster): add test.sh to verify cross-node replication"
```

---

### Task 5: HA cluster README

**Files:**
- Create: `ha-cluster/README.md`

- [ ] **Step 1: Create ha-cluster/README.md**

````markdown
# ArcadeDB 3-Node HA Cluster

A 3-node ArcadeDB cluster using Raft consensus for high availability, deployed via Docker Compose.

## What This Demonstrates

- ArcadeDB HA mode with Raft-based leader election
- Automatic replication across 3 nodes (`replicationFactor=3`)
- Reads served by any node in the cluster

## Prerequisites

- Docker >= 24.0
- Docker Compose >= 2.0
- `curl` and `jq`

## Quick Start

```bash
# Start the cluster (brings up 3 nodes and waits for all to be healthy)
./start.sh

# Verify the cluster is working (write on node1, read from node2 and node3)
./test.sh

# Tear down
docker compose down -v
```

## Configuration

| Property | Value | Description |
|----------|-------|-------------|
| `arcadedb.server.rootPassword` | `arcadedb` | Root user password — change for production |
| `arcadedb.ha.serverList` | `node1:2424,node2:2424,node3:2424` | Cluster member list |
| `arcadedb.ha.replicationFactor` | `3` | All nodes hold a full replica |

## Ports

| Node | HTTP API | Binary / HA |
|------|----------|-------------|
| node1 | 2480 | 2424 |
| node2 | 2481 | 2425 |
| node3 | 2482 | 2426 |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCADEDB_USER` | `root` | ArcadeDB username |
| `ARCADEDB_PASS` | `arcadedb` | ArcadeDB password |
| `NODE1_URL` | `http://localhost:2480` | node1 HTTP endpoint |
| `NODE2_URL` | `http://localhost:2481` | node2 HTTP endpoint |
| `NODE3_URL` | `http://localhost:2482` | node3 HTTP endpoint |
````

- [ ] **Step 2: Commit**

```bash
git add ha-cluster/README.md
git commit -m "docs(ha-cluster): add scenario README"
```

---

### Task 6: GitHub Actions CI workflow

**Files:**
- Create: `.github/workflows/ha-cluster.yml`

- [ ] **Step 1: Create .github/workflows/ha-cluster.yml**

```yaml
name: HA Cluster CI

on:
  push:
    paths:
      - ha-cluster/**
      - .github/workflows/ha-cluster.yml
  pull_request:
    paths:
      - ha-cluster/**
      - .github/workflows/ha-cluster.yml

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 15

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Start HA cluster
        run: ./ha-cluster/start.sh

      - name: Test HA cluster
        run: ./ha-cluster/test.sh

      - name: Tear down
        if: always()
        working-directory: ha-cluster
        run: docker compose down -v
```

- [ ] **Step 2: Validate workflow YAML**

```bash
docker compose -f ha-cluster/docker-compose.yml config > /dev/null && echo "compose ok"
# Workflow YAML will be validated by GitHub on push — check Actions tab after commit
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ha-cluster.yml
git commit -m "ci: add GitHub Actions workflow for HA cluster scenario"
```

---

### Task 7: Dependabot configuration

**Files:**
- Create: `.github/dependabot.yml`

- [ ] **Step 1: Create .github/dependabot.yml**

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

Note: add a `docker` entry for `/single-node` and a `helm` entry for `/kubernetes` when those scenarios are added.

- [ ] **Step 2: Commit**

```bash
git add .github/dependabot.yml
git commit -m "chore: add dependabot for docker image and github-actions versions"
```

---

## Self-Review Notes

- **Spec coverage:** All nine files from the file map are covered across tasks 1–7. Root README ✓, mergify ✓, pre-commit ✓, dependabot ✓, workflow ✓, docker-compose ✓, start.sh ✓, test.sh ✓, ha-cluster README ✓.
- **Placeholders:** None. All files contain complete content; the pre-commit config uses exact revisions from the usecases repo.
- **Type consistency:** `command_on` and `query_on` function names are consistent between task descriptions and the code in task 4. Node URL variable names (`NODE1_URL`, `NODE2_URL`, `NODE3_URL`) are consistent across start.sh and test.sh.
- **ArcadeDB HA property names** (`arcadedb.ha.serverList`, `arcadedb.ha.replicationFactor`) should be verified against the ArcadeDB docs — adjust in docker-compose.yml if the actual property names differ.
