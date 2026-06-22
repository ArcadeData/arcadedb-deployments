# Spring Boot Embedded ArcadeDB HA Cluster

Three Spring Boot applications, each embedding an ArcadeDB server, that form a Raft
high-availability cluster among themselves — no standalone database server. On top of the
cluster they implement the [recommendation engine](https://arcadedb.com/recommendation-engine.html)
use case (graph + vector + time-series) exposed as a REST API.

## What This Demonstrates

- ArcadeDB running **embedded** inside a Spring Boot JVM (`ArcadeDBServer` as a bean)
- Three embedded instances forming a Raft cluster with automatic leader election
- Leader-only schema/data bootstrap, replicated to followers
- Any node serving reads; writes forwarded to the leader

## Prerequisites

- Docker >= 24.0 and Docker Compose >= 2.0
- `curl` and `jq`
- (For local builds/tests) JDK 25 and Maven 3.9+

## Quick Start

```bash
# Build images, start 3 nodes, wait for a leader
./start.sh

# Verify replication and any-node reads
./test.sh

# Tear down
docker compose down -v
```

## REST API

Each node serves the same API (host ports 8080 / 8081 / 8082):

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/recommendations/collaborative/{userId}` | Collaborative filtering (graph) |
| GET | `/api/recommendations/similar/{productName}` | Vector similarity to a product |
| GET | `/api/recommendations/trending` | Trending products (time-series) |
| GET | `/api/recommendations/shows/{userId}` | Show recommendations (graph MATCH) |
| GET | `/api/recommendations/category/{category}/{userId}` | Personalized category page (vector) |
| GET | `/api/recommendations/hybrid/{userId}` | Hybrid graph + vector + time-series |
| GET | `/api/cluster/status` | Node name, leader flag, configured servers |
| GET | `/api/health` | Liveness/readiness (used by the compose healthcheck) |

Example:
```bash
curl -s http://localhost:8080/api/recommendations/collaborative/u1 | jq .
```

## Configuration

| Env var | Default | Description |
|---------|---------|-------------|
| `NODE_NAME` | `app-0` | Server name; must match `<prefix>-<integer>` |
| `HA_SERVER_LIST` | `app-0:2434:2480,...` | Cluster members (`host:raftPort:httpPort`) |
| `ARCADEDB_PASS` | `arcadedb` | Root password — change for production |
| `ARCADEDB_DATA_PATH` | `/app/data` | Embedded database directory (mounted volume) |

## Ports

| Node | REST (host) | ArcadeDB HTTP (internal) | Raft (internal) |
|------|-------------|--------------------------|-----------------|
| app-0 | 8080 | 2480 | 2434 |
| app-1 | 8081 | 2480 | 2434 |
| app-2 | 8082 | 2480 | 2434 |

The ArcadeDB HTTP port (`2480`) is **not** host-mapped; it stays on the internal network for
replica→leader write forwarding. The Spring REST API is the only public surface.

## Notes

- Each node's name is also its network hostname and must be DNS-resolvable by the other nodes. Docker Compose service names (`app-0`, `app-1`, `app-2`) provide this automatically; the `app-N` convention keeps names stable and readable.
- ArcadeDB Studio is excluded from the build; this scenario is API-only.
- Targets ArcadeDB 26.6.1, Spring Boot 3.5.x, Java 25.
