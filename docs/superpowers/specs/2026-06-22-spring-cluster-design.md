# spring-cluster — Embedded ArcadeDB HA Cluster with Spring Boot

**Status:** Approved design
**Date:** 2026-06-22

## 1. Goal & placement

Add a third deployment scenario to `arcadedb-deployments`, alongside `ha-cluster`
(Docker Compose) and `kubernetes` (Helm). The `spring-cluster` scenario demonstrates
**embedded ArcadeDB HA**: three Spring Boot applications, each running an in-JVM
`ArcadeDBServer`, that form a Raft cluster among themselves — with no standalone
ArcadeDB server. On top of that cluster it implements the
[recommendation-engine](https://arcadedb.com/recommendation-engine.html) use case
(graph + vector + time-series signals), exposed as a REST API.

It is added as a new row in the root `README.md` scenario table.

## 2. Architecture & data flow

```
        ┌──────────── docker network: arcadedb-cluster ────────────┐
        │                                                          │
   app-0 (leader)            app-1 (replica)          app-2 (replica)
   Spring Boot               Spring Boot              Spring Boot
   ├─ REST :8080             ├─ REST :8080            ├─ REST :8080
   └─ embedded ArcadeDBServer  └─ embedded ArcadeDBServer  └─ embedded ...
        Raft :2434  <───────────  Raft :2434  ───────────>  Raft :2434
        HTTP :2480  <─── write forwarding (replica→leader) ───>  HTTP :2480
   host :8080                host :8081               host :8082
```

The ArcadeDB HTTP port (`2480`) is open on the internal Docker network only — it is **not**
the public surface (that is the Spring REST API) but it **must** stay enabled and
reachable between nodes, because a write issued on a follower is forwarded to the leader
over HTTP.

- Each container builds from one Dockerfile (the Spring Boot fat jar) and runs with a
  distinct `NODE_NAME` (`app-0` / `app-1` / `app-2`) and a shared `HA_SERVER_LIST`.
- Raft elects a leader; the leader auto-seeds schema + sample data once; replication
  propagates it to the followers.
- **Reads** are served by any node; **writes** route through the leader. `test.sh`
  exploits this: verify on the leader, then read the same result from each follower to
  prove replication and any-node reads.

## 3. Module layout

```
spring-cluster/
├── README.md
├── Dockerfile                  # multi-stage: maven build → eclipse-temurin:25-jre
├── docker-compose.yml          # 3 explicit services app-0/1/2 (no YAML anchors)
├── start.sh                    # compose up --build + wait for healthy + leader elected
├── test.sh                     # verify replication / any-node reads
├── pom.xml
└── src/main/
    ├── java/com/arcadedb/examples/springcluster/
    │   ├── SpringClusterApplication.java
    │   ├── config/EmbeddedServerProperties.java   # @ConfigurationProperties("arcadedb")
    │   ├── config/EmbeddedArcadeDbServer.java      # SmartLifecycle: build cfg, start()/stop()
    │   ├── bootstrap/ClusterBootstrap.java         # ApplicationRunner, leader-only seed
    │   ├── recommendation/RecommendationService.java
    │   ├── recommendation/RecommendationController.java
    │   └── cluster/ClusterController.java
    └── resources/
        ├── application.yml
        ├── schema.sql          # reused from recommendation-engine (vector indexes, 4-dim)
        └── data.sql            # reused sample data
```

The CI workflow lives at the repo root under `.github/workflows/` (see §8), matching the
existing per-scenario workflows.

## 4. Embedded server lifecycle (`EmbeddedArcadeDbServer`)

A Spring `SmartLifecycle` bean translates Spring config into an ArcadeDB
`ContextConfiguration` and owns the embedded server's lifecycle.

Configuration applied via `GlobalConfiguration` keys (verified present in
`arcadedb-engine` 26.6.1):

| Key | Value |
|-----|-------|
| `SERVER_NAME` | `app-0` / `app-1` / `app-2` (from `NODE_NAME`) |
| `SERVER_ROOT_PATH` | per-node data directory (mounted volume) |
| `SERVER_ROOT_PASSWORD` | from `ARCADEDB_PASS` (default `arcadedb`) |
| `HA_ENABLED` | `true` |
| `HA_SERVER_LIST` | shared member list, `host:raftPort:httpPort` (e.g. `app-0:2434:2480,app-1:2434:2480,app-2:2434:2480`), mirroring the proven `ha-cluster` value |
| `HA_RAFT_PORT` | `2434` |
| `HA_QUORUM` | `majority` |
| `HA_CLUSTER_NAME` | `arcadedb` |

Lifecycle:

- Construct `new ArcadeDBServer(contextConfiguration)`; call `start()` on Spring startup
  and `stop()` on shutdown.
- ArcadeDB's HTTP server is **enabled** on port `2480` (internal Docker network only). It
  is required for replica→leader write forwarding, so it cannot be disabled. The public
  surface remains the Spring REST API; the ArcadeDB HTTP port is not host-mapped. The
  `arcadedb-studio` artifact is excluded from the `arcadedb-server` dependency (Maven
  exclusion) so the UI is never on the classpath — "no studio" without disabling HTTP.
- The `ServerDatabase` is exposed to the service **lazily** (resolved on first request,
  not at boot) so followers serve correctly once the database replicates in.
- Server names follow the required `<prefix>-<integer>` pattern (`app-0`), per the known
  ArcadeDB Raft naming constraint (a numeric suffix identifies peers).

## 5. Leader bootstrap (`ClusterBootstrap`)

An `ApplicationRunner` waits for a leader to be elected, then:

- If `server.getHA().isLeader()` → create the database, **broadcast its creation to the
  replicas**, then create the schema and insert the sample data idempotently (`IF NOT EXISTS`).
- Else → do nothing; replication delivers the schema and data.

Re-runs are safe. The loader polls for leadership with a bounded timeout and logs the
outcome (leader seeded / follower waiting).

**Distributed-creation requirement (discovered in Task 10 against a real 3-node cluster):**
`getOrCreateDatabase()` on the leader creates the database only locally. The followers then
receive the schema Raft entries for a database that does not exist on their side and crash
with `DatabaseOperationException`. The leader must therefore push the database to peers
before applying schema:
```java
if (db.getWrappedDatabaseInstance() instanceof HAReplicatedDatabase haDb) {
  haDb.createInReplicas();   // sends INSTALL_DATABASE_ENTRY to all peers
}
```
The `instanceof` guard makes this a no-op in single-node/embedded-test mode (the wrapped
instance is not an `HAReplicatedDatabase` there), so unit/integration tests are unaffected.

## 6. REST API

All responses are JSON DTOs (not console prints). The `RecommendationService` holds the
same six queries as the existing `RecommendationEngine.java`, run against the embedded
`ServerDatabase` via `query("cypher", …)` / `query("sql", …)`.

| Method | Path | Underlying query | Signal |
|--------|------|------------------|--------|
| GET | `/api/recommendations/collaborative/{userId}` | Q1 Cypher | graph |
| GET | `/api/recommendations/similar/{productName}` | Q2 `vectorNeighbors` | vector |
| GET | `/api/recommendations/trending` | Q3 | time-series |
| GET | `/api/recommendations/shows/{userId}` | Q4 `MATCH` | graph |
| GET | `/api/recommendations/category/{category}/{userId}` | Q5 | vector |
| GET | `/api/recommendations/hybrid/{userId}` | Q6 | graph + vector + ts |
| GET | `/api/cluster/status` | `getHA()`: leader name, this node, replica addresses | — |
| GET | `/api/health` | lightweight liveness/readiness for the compose healthcheck | — |

For personalized vector queries (Q2/Q5), the user's stored 4-dim embedding is used as the
query vector.

## 7. Docker & scripts

- **Dockerfile** — multi-stage: Maven build stage → `eclipse-temurin:25-jre` runtime
  carrying the fat jar.
- **docker-compose.yml** — three explicit service blocks (`app-0/1/2`, no YAML anchors,
  per the showcase readability convention), each with a per-node named volume for data
  persistence, the shared `arcadedb-cluster` network, host ports `8080/8081/8082` for the
  Spring REST API, and a healthcheck hitting `/api/health`. The ArcadeDB HTTP port `2480`
  is reachable on the internal network for write forwarding but is not host-mapped.
- **start.sh** — `docker compose up -d --build`, poll `/api/health` on all three, then
  poll `/api/cluster/status` until exactly one leader is reported.
- **test.sh** — confirm exactly one leader; fetch a recommendation (e.g. collaborative
  for `u1`) from all three nodes and assert identical results; optionally write a new
  interaction via the leader and read it back from a follower to demonstrate replication.

## 8. CI

A GitHub Actions workflow (`.github/workflows/spring-cluster-ci.yml`) mirroring the
existing `ha-cluster` / `kubernetes` workflows: trigger on push / PR touching
`spring-cluster/**` plus `workflow_dispatch`; build the jar, run `start.sh`, run
`test.sh`, tear down.

## 8.1 Dependabot

Extend the existing `.github/dependabot.yml` with entries covering the new module, in the
same style (weekly schedule, `dependencies` label):

- `package-ecosystem: "maven"`, `directory: "/spring-cluster"` — the Spring Boot / ArcadeDB
  dependency versions in `pom.xml`.
- `package-ecosystem: "docker"`, `directory: "/spring-cluster"` — the `eclipse-temurin`
  base image in the `Dockerfile`.
- `package-ecosystem: "docker-compose"`, `directory: "/spring-cluster"` — any pinned image
  tags in `docker-compose.yml`.

The existing `github-actions` (root) and `pre-commit` (root) entries already cover the new
CI workflow and hooks; no change needed there.

## 9. Versions & dependencies

- ArcadeDB **26.6.1**, Spring Boot **3.5.x**, Java **25**.
- Maven dependencies (minimal):
  - `com.arcadedb:arcadedb-server` (pulls the engine), with `arcadedb-studio` excluded.
  - `com.arcadedb:arcadedb-ha-raft` — **required** for embedded Raft HA. `arcadedb-server`
    does NOT transitively provide the Raft consensus implementation; without it the embedded
    server starts in standalone mode and never elects a leader. (Discovered during
    implementation, Task 3.)
  - `org.springframework.boot:spring-boot-starter-web`.
- No Actuator: the health endpoint is a plain Spring MVC controller.

## 10. Out of scope (YAGNI)

- No Spring Data / repository abstraction — there is no official ArcadeDB Spring Data
  module, and the direct `ServerDatabase` API is clearer for a showcase.
- No authentication beyond the root password.
- No UI / ArcadeDB Studio.

## 11. Risks / to verify during implementation

- **`HA_SERVER_LIST` exact format** for the embedded server (host-only vs.
  `host:raftPort:httpPort`). Mirror the working `ha-cluster` value and confirm against a
  running cluster.
- **Database creation on followers** — confirm followers resolve the replicated database
  without attempting a local write; the lazy-resolution approach (§4) is the mitigation.
- **Leader election timing** in `start.sh` / `ClusterBootstrap` — bounded polling with
  clear timeouts.
- **`arcadedb-studio` exclusion** — confirm the artifact coordinates and that excluding
  the UI does not break `arcadedb-server` startup with the HTTP listener **enabled**
  (required for write forwarding).
- **Inter-node HTTP reachability** — the ArcadeDB HTTP port `2480` must be open between
  containers on the internal network for replica→leader write forwarding; confirm the
  `host:raftPort:httpPort` entries match the listener configuration.
