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

# Verify the cluster is working (write on node-0, read from node-1 and node-2)
./test.sh

# Tear down
docker compose down -v
```

## Configuration

| Property | Value | Description |
|----------|-------|-------------|
| `arcadedb.server.rootPassword` | `arcadedb` | Root user password — change for production |
| `arcadedb.ha.enabled` | `true` | Enables HA mode |
| `arcadedb.ha.serverList` | `node-0:2434:2480,...` | Cluster member list (`host:raftPort:httpPort`) |
| `arcadedb.ha.replicationFactor` | `3` | All nodes hold a full replica |

## Ports

| Node | HTTP API | Raft |
|------|----------|-------------|
| node-0 | 2480 | 2424 → 2434 |
| node-1 | 2481 | 2425 → 2434 |
| node-2 | 2482 | 2426 → 2434 |

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ARCADEDB_USER` | `root` | ArcadeDB username |
| `ARCADEDB_PASS` | `arcadedb` | ArcadeDB password |
| `NODE1_URL` | `http://localhost:2480` | node-0 HTTP endpoint |
| `NODE2_URL` | `http://localhost:2481` | node-1 HTTP endpoint |
| `NODE3_URL` | `http://localhost:2482` | node-2 HTTP endpoint |

## Notes

- Server names must follow the pattern `<prefix>-<integer>` (e.g., `node-0`). ArcadeDB v26.4.2 Raft requires a numeric suffix to identify peers. Names like `node1` cause an `IllegalArgumentException` at startup.
- The root password is set via `JAVA_OPTS` rather than an environment variable due to a known limitation in the current ArcadeDB release.
