# spring-cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `spring-cluster` deployment scenario where three Spring Boot apps each embed an ArcadeDB server, form a Raft HA cluster, and serve the recommendation-engine use case over REST.

**Architecture:** Each Spring Boot app starts an in-JVM `ArcadeDBServer` with HA enabled (a `SmartLifecycle` bean). The three nodes elect a Raft leader; the leader seeds schema + sample data once and replication propagates it. A `RecommendationService` runs graph/vector/time-series queries against the embedded `ServerDatabase`, exposed by `@RestController`s. Docker Compose runs the 3 nodes; `start.sh`/`test.sh` orchestrate and verify; a CI workflow runs them.

**Tech Stack:** Java 25, Spring Boot 3.5.x, ArcadeDB 26.6.1 (`arcadedb-server`, embedded HA), Maven, Docker Compose, bash + `jq` + `curl`.

## Global Constraints

- Java **25** (Maven `release` 25; runtime base `eclipse-temurin:25-jre`).
- ArcadeDB **26.6.1**; Spring Boot **3.5.x** (pin a concrete recent patch, e.g. `3.5.6`; Dependabot bumps it).
- Minimal dependencies: `com.arcadedb:arcadedb-server` (with `arcadedb-studio` **excluded**) and `spring-boot-starter-web`. `spring-boot-starter-test` is **test scope** only. No Actuator.
- ArcadeDB's HTTP server stays **enabled** on port `2480` (internal network only) — required for replica→leader write forwarding. No Studio on the classpath.
- Server names must match `<prefix>-<integer>`: `app-0`, `app-1`, `app-2`.
- Database name: `RecommendationEngine`. Vectors are 4-dimensional (`COSINE`).
- Docker Compose uses three explicit service blocks (no YAML anchors). Host ports `8080/8081/8082` map to each node's Spring REST; ArcadeDB `2480` is not host-mapped.
- Reference spec: `docs/superpowers/specs/2026-06-22-spring-cluster-design.md`.

---

## File Structure

```
spring-cluster/
├── README.md                                            # Task 11
├── Dockerfile                                           # Task 9
├── docker-compose.yml                                   # Task 10
├── start.sh                                             # Task 10
├── test.sh                                              # Task 10
├── pom.xml                                              # Task 1
└── src/
    ├── main/
    │   ├── java/com/arcadedb/examples/springcluster/
    │   │   ├── SpringClusterApplication.java            # Task 1
    │   │   ├── config/EmbeddedServerProperties.java     # Task 2
    │   │   ├── config/EmbeddedArcadeDbServer.java       # Task 3
    │   │   ├── bootstrap/ClusterBootstrap.java          # Task 5
    │   │   ├── recommendation/RecommendationService.java# Task 6
    │   │   ├── recommendation/RecommendationController.java # Task 7
    │   │   ├── cluster/ClusterController.java            # Task 8
    │   │   └── cluster/HealthController.java             # Task 8
    │   └── resources/
    │       ├── application.yml                          # Task 1
    │       ├── schema.sql                               # Task 4 (copied verbatim)
    │       └── data.sql                                 # Task 4 (copied verbatim)
    └── test/java/com/arcadedb/examples/springcluster/
        ├── SpringClusterApplicationTests.java           # Task 1
        ├── config/EmbeddedServerPropertiesTest.java     # Task 2
        ├── config/EmbeddedArcadeDbServerIT.java         # Task 3
        ├── bootstrap/ClusterBootstrapIT.java            # Task 5
        ├── recommendation/RecommendationServiceIT.java  # Task 6
        ├── recommendation/RecommendationControllerIT.java # Task 7
        └── cluster/ClusterEndpointsIT.java              # Task 8

.github/workflows/spring-cluster.yml                     # Task 12
.github/dependabot.yml                                   # Task 12 (modify)
README.md                                                # Task 11 (modify root table)
```

The `*IT` integration tests start a real single-node embedded HA server (it elects itself
leader with a one-member server list). They share a fixed test config: node `app-0`, raft
port `12434`, http port `12480`, data path `target/it-arcadedb`.

---

### Task 1: Maven skeleton + bootable Spring app

**Files:**
- Create: `spring-cluster/pom.xml`
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/SpringClusterApplication.java`
- Create: `spring-cluster/src/main/resources/application.yml`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/SpringClusterApplicationTests.java`

**Interfaces:**
- Produces: a runnable Spring Boot app (`SpringClusterApplication`) and a buildable jar named `spring-cluster.jar`. No embedded DB yet.

- [ ] **Step 1: Write the failing test**

`spring-cluster/src/test/java/com/arcadedb/examples/springcluster/SpringClusterApplicationTests.java`:
```java
package com.arcadedb.examples.springcluster;

import org.junit.jupiter.api.Test;

class SpringClusterApplicationTests {

  @Test
  void mainClassExists() {
    // Compile-time proof the app entrypoint exists; full context load is exercised in Task 3+.
    org.junit.jupiter.api.Assertions.assertNotNull(SpringClusterApplication.class);
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=SpringClusterApplicationTests`
Expected: FAIL — compilation error, `SpringClusterApplication` does not exist.

- [ ] **Step 3: Write `pom.xml`**

`spring-cluster/pom.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>

  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.6</version>
    <relativePath/>
  </parent>

  <groupId>com.arcadedb.examples</groupId>
  <artifactId>spring-cluster</artifactId>
  <version>1.0-SNAPSHOT</version>
  <packaging>jar</packaging>

  <properties>
    <java.version>25</java.version>
    <arcadedb.version>26.6.1</arcadedb.version>
  </properties>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>

    <dependency>
      <groupId>com.arcadedb</groupId>
      <artifactId>arcadedb-server</artifactId>
      <version>${arcadedb.version}</version>
      <exclusions>
        <exclusion>
          <groupId>com.arcadedb</groupId>
          <artifactId>arcadedb-studio</artifactId>
        </exclusion>
      </exclusions>
    </dependency>

    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <finalName>spring-cluster</finalName>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

> If `arcadedb-studio` is not actually a transitive dependency of `arcadedb-server` in 26.6.1, the exclusion is a harmless no-op — keep it as intent. Verify with `mvn -q dependency:tree | grep -i studio` returning nothing.

- [ ] **Step 4: Write `SpringClusterApplication.java`**

`spring-cluster/src/main/java/com/arcadedb/examples/springcluster/SpringClusterApplication.java`:
```java
package com.arcadedb.examples.springcluster;

import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties(EmbeddedServerProperties.class)
public class SpringClusterApplication {

  public static void main(String[] args) {
    SpringApplication.run(SpringClusterApplication.class, args);
  }
}
```

> This references `EmbeddedServerProperties` (Task 2). To keep Task 1 compiling on its own,
> create a minimal placeholder now is **not** allowed (no placeholders). Instead, implement
> Task 2's `EmbeddedServerProperties` class body as part of making this compile — Step 4 here
> and Task 2 Step 3 produce the same file. If executing strictly in order, drop the
> `@EnableConfigurationProperties` line and the import in this step, then add them in Task 2
> Step 5.

- [ ] **Step 5: Write `application.yml`**

`spring-cluster/src/main/resources/application.yml`:
```yaml
spring:
  application:
    name: spring-cluster
server:
  port: 8080
arcadedb:
  node-name: ${NODE_NAME:app-0}
  server-list: ${HA_SERVER_LIST:app-0:2434:2480}
  root-password: ${ARCADEDB_PASS:arcadedb}
  database-name: ${ARCADEDB_DATABASE:RecommendationEngine}
  data-path: ${ARCADEDB_DATA_PATH:./target/arcadedb}
  http-port: ${ARCADEDB_HTTP_PORT:2480}
  raft-port: ${ARCADEDB_RAFT_PORT:2434}
logging:
  level:
    com.arcadedb: INFO
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=SpringClusterApplicationTests`
Expected: PASS (1 test). If you kept `@EnableConfigurationProperties`, do Task 2 first.

- [ ] **Step 7: Commit**

```bash
git add spring-cluster/pom.xml spring-cluster/src
git commit -m "feat(spring-cluster): scaffold spring boot module"
```

---

### Task 2: Embedded server configuration properties

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/config/EmbeddedServerProperties.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/config/EmbeddedServerPropertiesTest.java`

**Interfaces:**
- Produces: `EmbeddedServerProperties` with getters `getNodeName()`, `getServerList()`, `getRootPassword()`, `getDatabaseName()`, `getDataPath()`, `getHttpPort()` (int), `getRaftPort()` (int), bound from prefix `arcadedb`.

- [ ] **Step 1: Write the failing test**

`.../config/EmbeddedServerPropertiesTest.java`:
```java
package com.arcadedb.examples.springcluster.config;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class EmbeddedServerPropertiesTest {

  @Test
  void holdsConfiguredValues() {
    EmbeddedServerProperties p = new EmbeddedServerProperties();
    p.setNodeName("app-1");
    p.setServerList("app-0:2434:2480,app-1:2434:2480");
    p.setRaftPort(2434);
    p.setHttpPort(2480);

    assertEquals("app-1", p.getNodeName());
    assertEquals("app-0:2434:2480,app-1:2434:2480", p.getServerList());
    assertEquals(2434, p.getRaftPort());
    assertEquals(2480, p.getHttpPort());
    assertEquals("RecommendationEngine", p.getDatabaseName()); // default
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=EmbeddedServerPropertiesTest`
Expected: FAIL — `EmbeddedServerProperties` does not exist.

- [ ] **Step 3: Write `EmbeddedServerProperties.java`**

```java
package com.arcadedb.examples.springcluster.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "arcadedb")
public class EmbeddedServerProperties {

  private String nodeName = "app-0";
  private String serverList = "app-0:2434:2480";
  private String rootPassword = "arcadedb";
  private String databaseName = "RecommendationEngine";
  private String dataPath = "./target/arcadedb";
  private int httpPort = 2480;
  private int raftPort = 2434;

  public String getNodeName() { return nodeName; }
  public void setNodeName(String nodeName) { this.nodeName = nodeName; }

  public String getServerList() { return serverList; }
  public void setServerList(String serverList) { this.serverList = serverList; }

  public String getRootPassword() { return rootPassword; }
  public void setRootPassword(String rootPassword) { this.rootPassword = rootPassword; }

  public String getDatabaseName() { return databaseName; }
  public void setDatabaseName(String databaseName) { this.databaseName = databaseName; }

  public String getDataPath() { return dataPath; }
  public void setDataPath(String dataPath) { this.dataPath = dataPath; }

  public int getHttpPort() { return httpPort; }
  public void setHttpPort(int httpPort) { this.httpPort = httpPort; }

  public int getRaftPort() { return raftPort; }
  public void setRaftPort(int raftPort) { this.raftPort = raftPort; }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=EmbeddedServerPropertiesTest`
Expected: PASS.

- [ ] **Step 5: Ensure registration**

Confirm `SpringClusterApplication` has `@EnableConfigurationProperties(EmbeddedServerProperties.class)` and its import (added in Task 1 Step 4, or add now).

- [ ] **Step 6: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/config/EmbeddedServerProperties.java \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/config/EmbeddedServerPropertiesTest.java \
        spring-cluster/src/main/java/com/arcadedb/examples/springcluster/SpringClusterApplication.java
git commit -m "feat(spring-cluster): add embedded server configuration properties"
```

---

### Task 3: Embedded ArcadeDB server lifecycle

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/config/EmbeddedArcadeDbServer.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/config/EmbeddedArcadeDbServerIT.java`

**Interfaces:**
- Consumes: `EmbeddedServerProperties`.
- Produces: `@Component EmbeddedArcadeDbServer implements SmartLifecycle` with:
  - `ArcadeDBServer server()` — the started server.
  - `boolean isLeader()` — true when this node is the Raft leader.
  - `ServerDatabase database()` — returns `server().getDatabase(databaseName)` (must already exist; created by the leader in Task 5).
  - `boolean isRunning()`.

- [ ] **Step 1: Write the failing test**

`.../config/EmbeddedArcadeDbServerIT.java`:
```java
package com.arcadedb.examples.springcluster.config;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import java.time.Duration;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertTrue;

@SpringBootTest(properties = {
    "arcadedb.node-name=app-0",
    "arcadedb.server-list=app-0:12434:12480",
    "arcadedb.raft-port=12434",
    "arcadedb.http-port=12480",
    "arcadedb.data-path=target/it-arcadedb/task3"
})
class EmbeddedArcadeDbServerIT {

  @Autowired
  EmbeddedArcadeDbServer embedded;

  @Test
  void startsAndBecomesLeader() {
    assertTrue(embedded.server().isStarted(), "server should be started");

    Instant deadline = Instant.now().plus(Duration.ofSeconds(60));
    while (Instant.now().isBefore(deadline) && !embedded.isLeader()) {
      sleep(500);
    }
    assertTrue(embedded.isLeader(), "single node should elect itself leader");
  }

  private static void sleep(long ms) {
    try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=EmbeddedArcadeDbServerIT`
Expected: FAIL — `EmbeddedArcadeDbServer` does not exist.

- [ ] **Step 3: Write `EmbeddedArcadeDbServer.java`**

```java
package com.arcadedb.examples.springcluster.config;

import com.arcadedb.ContextConfiguration;
import com.arcadedb.GlobalConfiguration;
import com.arcadedb.server.ArcadeDBServer;
import com.arcadedb.server.ServerDatabase;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

@Component
public class EmbeddedArcadeDbServer implements SmartLifecycle {

  private static final Logger log = LoggerFactory.getLogger(EmbeddedArcadeDbServer.class);

  private final EmbeddedServerProperties props;
  private ArcadeDBServer server;
  private volatile boolean running;

  public EmbeddedArcadeDbServer(EmbeddedServerProperties props) {
    this.props = props;
  }

  @Override
  public void start() {
    ContextConfiguration cfg = new ContextConfiguration();
    cfg.setValue(GlobalConfiguration.SERVER_NAME, props.getNodeName());
    cfg.setValue(GlobalConfiguration.SERVER_ROOT_PATH, props.getDataPath());
    cfg.setValue(GlobalConfiguration.SERVER_DATABASE_DIRECTORY, props.getDataPath() + "/databases");
    cfg.setValue(GlobalConfiguration.SERVER_ROOT_PASSWORD, props.getRootPassword());
    cfg.setValue(GlobalConfiguration.SERVER_HTTP_INCOMING_PORT, props.getHttpPort());
    cfg.setValue(GlobalConfiguration.HA_ENABLED, true);
    cfg.setValue(GlobalConfiguration.HA_SERVER_LIST, props.getServerList());
    cfg.setValue(GlobalConfiguration.HA_RAFT_PORT, props.getRaftPort());
    cfg.setValue(GlobalConfiguration.HA_QUORUM, "majority");
    cfg.setValue(GlobalConfiguration.HA_CLUSTER_NAME, "arcadedb");

    server = new ArcadeDBServer(cfg);
    server.start();
    running = true;
    log.info("Embedded ArcadeDB server '{}' started (raft={}, http={})",
        props.getNodeName(), props.getRaftPort(), props.getHttpPort());
  }

  @Override
  public void stop() {
    if (server != null && server.isStarted()) {
      server.stop();
    }
    running = false;
  }

  @Override
  public boolean isRunning() {
    return running;
  }

  public ArcadeDBServer server() {
    return server;
  }

  public boolean isLeader() {
    return server != null && server.getHA() != null && server.getHA().isLeader();
  }

  public ServerDatabase database() {
    return server.getDatabase(props.getDatabaseName());
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=EmbeddedArcadeDbServerIT`
Expected: PASS. The single-node server elects itself leader within the 60s window.

> If `isLeader()` never turns true for a single-member list, the `HA_SERVER_LIST` format or
> quorum is off. Inspect logs for the elected leader line; try `arcadedb.server-list=app-0`
> (host only) vs. `app-0:12434:12480`. Record the working format — it drives Task 10's compose
> file. This is the spec's flagged risk (`HA_SERVER_LIST` exact format).

- [ ] **Step 5: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/config/EmbeddedArcadeDbServer.java \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/config/EmbeddedArcadeDbServerIT.java
git commit -m "feat(spring-cluster): embed ArcadeDB HA server as a SmartLifecycle bean"
```

---

### Task 4: Schema and data resources

**Files:**
- Create: `spring-cluster/src/main/resources/schema.sql`
- Create: `spring-cluster/src/main/resources/data.sql`

**Interfaces:**
- Produces: two classpath SQL scripts consumed by Task 5. `schema.sql` is idempotent
  (`IF NOT EXISTS`); `data.sql` is plain inserts (Task 5 guards against double-seed).

- [ ] **Step 1: Copy `schema.sql` verbatim**

Copy `../arcadedb-usecases/recommendation-engine/sql/01-schema.sql` to
`spring-cluster/src/main/resources/schema.sql`. Exact contents:
```sql
CREATE VERTEX TYPE User IF NOT EXISTS;
CREATE PROPERTY User.id IF NOT EXISTS STRING;
CREATE PROPERTY User.embedding IF NOT EXISTS LIST;
CREATE INDEX IF NOT EXISTS ON User (id) UNIQUE;
CREATE VERTEX TYPE Product IF NOT EXISTS;
CREATE PROPERTY Product.name IF NOT EXISTS STRING;
CREATE PROPERTY Product.category IF NOT EXISTS STRING;
CREATE PROPERTY Product.price IF NOT EXISTS FLOAT;
CREATE PROPERTY Product.inStock IF NOT EXISTS BOOLEAN;
CREATE PROPERTY Product.embedding IF NOT EXISTS LIST;
CREATE VERTEX TYPE Show IF NOT EXISTS;
CREATE PROPERTY Show.title IF NOT EXISTS STRING;
CREATE PROPERTY Show.genre IF NOT EXISTS STRING;
CREATE PROPERTY Show.embedding IF NOT EXISTS LIST;
CREATE EDGE TYPE PURCHASED IF NOT EXISTS;
CREATE EDGE TYPE WATCHED IF NOT EXISTS;
CREATE EDGE TYPE INTERACTED IF NOT EXISTS;
CREATE DOCUMENT TYPE ProductInteraction IF NOT EXISTS;
CREATE PROPERTY ProductInteraction.productId IF NOT EXISTS STRING;
CREATE PROPERTY ProductInteraction.purchaseCount IF NOT EXISTS LONG;
CREATE PROPERTY ProductInteraction.ts IF NOT EXISTS DATETIME;
CREATE INDEX IF NOT EXISTS ON Product (embedding) LSM_VECTOR METADATA { dimensions: 4, similarity: 'COSINE' };
CREATE INDEX IF NOT EXISTS ON Show (embedding) LSM_VECTOR METADATA { dimensions: 4, similarity: 'COSINE' };
```

- [ ] **Step 2: Copy `data.sql` verbatim**

Copy `../arcadedb-usecases/recommendation-engine/sql/02-data.sql` to
`spring-cluster/src/main/resources/data.sql` (the full 5-users / 10-products / 5-shows /
edges / ProductInteraction script). Do not edit it.

- [ ] **Step 3: Commit**

```bash
git add spring-cluster/src/main/resources/schema.sql spring-cluster/src/main/resources/data.sql
git commit -m "feat(spring-cluster): add recommendation-engine schema and sample data"
```

---

### Task 5: Leader-only schema/data bootstrap

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/bootstrap/ClusterBootstrap.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/bootstrap/ClusterBootstrapIT.java`

**Interfaces:**
- Consumes: `EmbeddedArcadeDbServer`, `EmbeddedServerProperties`, Spring `ResourceLoader`.
- Produces: `@Component ClusterBootstrap implements ApplicationRunner`. After startup, on the
  leader, the `RecommendationEngine` database exists with `User`=5, `Product`=10, `Show`=5.
  Idempotent across restarts.

- [ ] **Step 1: Write the failing test**

`.../bootstrap/ClusterBootstrapIT.java`:
```java
package com.arcadedb.examples.springcluster.bootstrap;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import com.arcadedb.server.ServerDatabase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.test.context.SpringBootTest;

import static org.junit.jupiter.api.Assertions.assertEquals;

@SpringBootTest(properties = {
    "arcadedb.node-name=app-0",
    "arcadedb.server-list=app-0:12435:12481",
    "arcadedb.raft-port=12435",
    "arcadedb.http-port=12481",
    "arcadedb.data-path=target/it-arcadedb/task5"
})
class ClusterBootstrapIT {

  @Autowired EmbeddedArcadeDbServer embedded;
  @Autowired EmbeddedServerProperties props;
  @Autowired ClusterBootstrap bootstrap;

  @Test
  void leaderSeedsSampleDataExactlyOnce() throws Exception {
    ServerDatabase db = embedded.server().getDatabase(props.getDatabaseName());
    assertEquals(5, db.countType("User", false));
    assertEquals(10, db.countType("Product", false));
    assertEquals(5, db.countType("Show", false));

    // Re-running the bootstrap must not duplicate data.
    bootstrap.run((ApplicationArguments) null);
    assertEquals(5, db.countType("User", false));
    assertEquals(10, db.countType("Product", false));
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=ClusterBootstrapIT`
Expected: FAIL — `ClusterBootstrap` does not exist.

- [ ] **Step 3: Write `ClusterBootstrap.java`**

```java
package com.arcadedb.examples.springcluster.bootstrap;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import com.arcadedb.server.ServerDatabase;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.core.io.ResourceLoader;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.time.Instant;
import java.util.Arrays;
import java.util.stream.Collectors;

@Component
public class ClusterBootstrap implements ApplicationRunner {

  private static final Logger log = LoggerFactory.getLogger(ClusterBootstrap.class);

  private final EmbeddedArcadeDbServer embedded;
  private final EmbeddedServerProperties props;
  private final ResourceLoader resourceLoader;

  public ClusterBootstrap(EmbeddedArcadeDbServer embedded, EmbeddedServerProperties props,
                          ResourceLoader resourceLoader) {
    this.embedded = embedded;
    this.props = props;
    this.resourceLoader = resourceLoader;
  }

  @Override
  public void run(ApplicationArguments args) throws Exception {
    if (!awaitLeaderElected(Duration.ofSeconds(60))) {
      log.warn("No leader elected within timeout on '{}'; skipping bootstrap", props.getNodeName());
      return;
    }
    if (!embedded.isLeader()) {
      log.info("Node '{}' is a follower; schema/data will replicate from the leader",
          props.getNodeName());
      return;
    }

    ServerDatabase db = embedded.server().getOrCreateDatabase(props.getDatabaseName());
    applyScript(db, "classpath:schema.sql");

    if (db.countType("User", false) == 0) {
      db.begin();
      try {
        applyScript(db, "classpath:data.sql");
        db.commit();
        log.info("Seeded sample data on leader '{}'", props.getNodeName());
      } catch (RuntimeException e) {
        db.rollback();
        throw e;
      }
    } else {
      log.info("Sample data already present on '{}'; skipping seed", props.getNodeName());
    }
  }

  private boolean awaitLeaderElected(Duration timeout) {
    Instant deadline = Instant.now().plus(timeout);
    while (Instant.now().isBefore(deadline)) {
      if (embedded.server() != null && embedded.server().getHA() != null
          && embedded.server().getHA().getLeaderName() != null) {
        return true;
      }
      try { Thread.sleep(500); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return false; }
    }
    return false;
  }

  private void applyScript(ServerDatabase db, String location) throws IOException {
    String content = resourceLoader.getResource(location)
        .getContentAsString(StandardCharsets.UTF_8);
    for (String raw : content.split(";")) {
      String stmt = Arrays.stream(raw.split("\n"))
          .filter(line -> !line.strip().startsWith("--"))
          .collect(Collectors.joining("\n"))
          .strip();
      if (!stmt.isEmpty()) {
        db.command("sql", stmt).close();
      }
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=ClusterBootstrapIT`
Expected: PASS. Counts are 5/10/5 and stable after a second `run`.

> If `db.command` on DDL fails inside the data transaction, note that only `data.sql` is wrapped
> in `begin/commit`; `schema.sql` runs before any transaction (DDL auto-commits). If inserts
> require no active transaction in your build, remove the `begin/commit` and rely on per-statement
> auto-commit — re-run the test to confirm.

- [ ] **Step 5: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/bootstrap/ClusterBootstrap.java \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/bootstrap/ClusterBootstrapIT.java
git commit -m "feat(spring-cluster): seed schema and data on the raft leader at startup"
```

---

### Task 6: Recommendation service (6 queries)

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/recommendation/RecommendationService.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/recommendation/RecommendationServiceIT.java`

**Interfaces:**
- Consumes: `EmbeddedArcadeDbServer`, `EmbeddedServerProperties`.
- Produces: `@Service RecommendationService` with:
  - `List<Map<String,Object>> collaborative(String userId)`
  - `List<Map<String,Object>> similarProducts(String productName)`
  - `List<Map<String,Object>> trending()`
  - `List<Map<String,Object>> shows(String userId)`
  - `List<Map<String,Object>> category(String category, String userId)`
  - `Map<String,Object> hybrid(String userId)` — keys `candidates`, `ranked`, `trending`.

- [ ] **Step 1: Write the failing test**

`.../recommendation/RecommendationServiceIT.java`:
```java
package com.arcadedb.examples.springcluster.recommendation;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

@SpringBootTest(properties = {
    "arcadedb.node-name=app-0",
    "arcadedb.server-list=app-0:12436:12482",
    "arcadedb.raft-port=12436",
    "arcadedb.http-port=12482",
    "arcadedb.data-path=target/it-arcadedb/task6"
})
class RecommendationServiceIT {

  @Autowired RecommendationService service;

  @Test
  void collaborativeTopForU1IsRunningShoes() {
    List<Map<String, Object>> rows = service.collaborative("u1");
    assertFalse(rows.isEmpty());
    assertEquals("Running Shoes", rows.get(0).get("name"));
  }

  @Test
  void trendingTopIsRunningShoes() {
    List<Map<String, Object>> rows = service.trending();
    assertEquals("Running Shoes", rows.get(0).get("productId"));
  }

  @Test
  void similarToLaptopReturnsElectronicsFirst() {
    List<Map<String, Object>> rows = service.similarProducts("Laptop");
    assertFalse(rows.isEmpty());
    assertEquals("Electronics", rows.get(0).get("category"));
  }

  @Test
  void showsForU1IncludeComedyShow() {
    List<Map<String, Object>> rows = service.shows("u1");
    assertTrue(rows.stream().anyMatch(r -> "Comedy Show".equals(r.get("title"))));
  }

  @Test
  void categoryElectronicsOnlyReturnsElectronics() {
    List<Map<String, Object>> rows = service.category("Electronics", "u1");
    assertFalse(rows.isEmpty());
    assertTrue(rows.stream().allMatch(r -> "Electronics".equals(r.get("category"))));
  }

  @Test
  void hybridReturnsCandidates() {
    Map<String, Object> result = service.hybrid("u1");
    assertTrue(result.containsKey("candidates"));
    assertFalse(((List<?>) result.get("candidates")).isEmpty());
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=RecommendationServiceIT`
Expected: FAIL — `RecommendationService` does not exist.

- [ ] **Step 3: Write `RecommendationService.java`**

```java
package com.arcadedb.examples.springcluster.recommendation;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import com.arcadedb.query.sql.executor.Result;
import com.arcadedb.query.sql.executor.ResultSet;
import com.arcadedb.server.ServerDatabase;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class RecommendationService {

  private final EmbeddedArcadeDbServer embedded;
  private final EmbeddedServerProperties props;

  public RecommendationService(EmbeddedArcadeDbServer embedded, EmbeddedServerProperties props) {
    this.embedded = embedded;
    this.props = props;
  }

  private ServerDatabase db() {
    return embedded.server().getDatabase(props.getDatabaseName());
  }

  // Q1 — collaborative filtering (graph)
  public List<Map<String, Object>> collaborative(String userId) {
    String cypher = """
        MATCH (me:User {id: $uid})-[:PURCHASED]->(p:Product)
              <-[:PURCHASED]-(other:User)-[:PURCHASED]->(rec:Product)
        WHERE rec <> p AND NOT (me)-[:PURCHASED]->(rec)
        RETURN rec.name AS name, rec.category AS category, count(DISTINCT other) AS score
        ORDER BY score DESC LIMIT 20""";
    return rows(db().query("cypher", cypher, Map.of("uid", userId)));
  }

  // Q2 — vector similarity to a product's embedding
  public List<Map<String, Object>> similarProducts(String productName) {
    List<Double> embedding = embeddingOf("Product", "name", productName);
    String sql = "SELECT name, category, price FROM Product WHERE inStock = true "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 20) DESC "
        + "LIMIT 20";
    return rows(db().query("sql", sql));
  }

  // Q3 — trending (time-series)
  public List<Map<String, Object>> trending() {
    String sql = "SELECT productId, sum(purchaseCount) AS totalInteractions "
        + "FROM ProductInteraction GROUP BY productId ORDER BY totalInteractions DESC LIMIT 10";
    return rows(db().query("sql", sql));
  }

  // Q4 — streaming collaborative (graph, SQL MATCH)
  public List<Map<String, Object>> shows(String userId) {
    String sql = "SELECT title, genre, count(*) AS collab_score FROM ( "
        + "MATCH {type: User, where: (id = :uid)}"
        + ".out('WATCHED'){as: show}"
        + ".in('WATCHED'){as: viewer, where: (id != :uid)}"
        + ".out('WATCHED'){as: rec, where: ($matched.show != @this)} "
        + "RETURN rec.title AS title, rec.genre AS genre "
        + ") GROUP BY title, genre ORDER BY collab_score DESC LIMIT 10";
    return rows(db().query("sql", sql, Map.of("uid", userId)));
  }

  // Q5 — personalized category page (vector)
  public List<Map<String, Object>> category(String category, String userId) {
    List<Double> embedding = embeddingOf("User", "id", userId);
    String sql = "SELECT name, category, price FROM Product "
        + "WHERE category = :cat AND inStock = true "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 30) DESC "
        + "LIMIT 30";
    return rows(db().query("sql", sql, Map.of("cat", category)));
  }

  // Q6 — hybrid multi-model (graph + vector + time-series)
  public Map<String, Object> hybrid(String userId) {
    Map<String, Object> out = new LinkedHashMap<>();

    String candidateCypher = """
        MATCH (me:User {id: $uid})-[:PURCHASED]->(p:Product)
              <-[:PURCHASED]-(other:User)-[:PURCHASED]->(rec:Product)
        WHERE rec <> p AND NOT (me)-[:PURCHASED]->(rec)
        RETURN DISTINCT rec.name AS name""";
    List<Map<String, Object>> candidates = rows(db().query("cypher", candidateCypher, Map.of("uid", userId)));
    out.put("candidates", candidates);

    if (candidates.isEmpty()) {
      out.put("ranked", List.of());
      out.put("trending", List.of());
      return out;
    }

    String inList = candidates.stream()
        .map(r -> "'" + String.valueOf(r.get("name")).replace("'", "''") + "'")
        .collect(Collectors.joining(", "));
    List<Double> embedding = embeddingOf("User", "id", userId);

    String rankedSql = "SELECT name, category, price FROM Product WHERE name IN [" + inList + "] "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 10) DESC";
    out.put("ranked", rows(db().query("sql", rankedSql)));

    String trendingSql = "SELECT productId, sum(purchaseCount) AS trending_score "
        + "FROM ProductInteraction WHERE productId IN [" + inList + "] "
        + "GROUP BY productId ORDER BY trending_score DESC";
    out.put("trending", rows(db().query("sql", trendingSql)));

    return out;
  }

  private List<Double> embeddingOf(String type, String keyProp, String keyValue) {
    String sql = "SELECT embedding FROM " + type + " WHERE " + keyProp + " = :k LIMIT 1";
    try (ResultSet rs = db().query("sql", sql, Map.of("k", keyValue))) {
      if (rs.hasNext()) {
        return rs.next().getProperty("embedding");
      }
    }
    throw new NoSuchElementException(type + " '" + keyValue + "' not found");
  }

  private static String formatVector(List<Double> vector) {
    return vector.stream().map(String::valueOf).collect(Collectors.joining(",", "[", "]"));
  }

  private static List<Map<String, Object>> rows(ResultSet rs) {
    List<Map<String, Object>> out = new ArrayList<>();
    try (rs) {
      while (rs.hasNext()) {
        Result r = rs.next();
        Map<String, Object> row = new LinkedHashMap<>();
        for (String name : r.getPropertyNames()) {
          row.put(name, r.getProperty(name));
        }
        out.add(row);
      }
    }
    return out;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=RecommendationServiceIT`
Expected: PASS (6 tests).

> `type`/`keyProp` in `embeddingOf` are fixed internal literals, never user input — safe to
> concatenate. `keyValue`, `userId`, `category` are bound as `:params`. If `getProperty("embedding")`
> returns a non-`List<Double>` type in your build, adapt `embeddingOf` to map the elements to
> `Double` before formatting.

- [ ] **Step 5: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/recommendation/RecommendationService.java \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/recommendation/RecommendationServiceIT.java
git commit -m "feat(spring-cluster): add recommendation service with graph, vector and time-series queries"
```

---

### Task 7: Recommendation REST controller

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/recommendation/RecommendationController.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/recommendation/RecommendationControllerIT.java`

**Interfaces:**
- Consumes: `RecommendationService`.
- Produces: REST endpoints under `/api/recommendations` returning JSON (see spec §6).

- [ ] **Step 1: Write the failing test**

`.../recommendation/RecommendationControllerIT.java`:
```java
package com.arcadedb.examples.springcluster.recommendation;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
        "arcadedb.node-name=app-0",
        "arcadedb.server-list=app-0:12437:12483",
        "arcadedb.raft-port=12437",
        "arcadedb.http-port=12483",
        "arcadedb.data-path=target/it-arcadedb/task7"
    })
class RecommendationControllerIT {

  @Autowired TestRestTemplate rest;

  @Test
  void collaborativeEndpointReturnsRunningShoes() {
    ResponseEntity<String> resp = rest.getForEntity("/api/recommendations/collaborative/u1", String.class);
    assertEquals(HttpStatus.OK, resp.getStatusCode());
    assertTrue(resp.getBody().contains("Running Shoes"), resp.getBody());
  }

  @Test
  void trendingEndpointReturnsOk() {
    ResponseEntity<String> resp = rest.getForEntity("/api/recommendations/trending", String.class);
    assertEquals(HttpStatus.OK, resp.getStatusCode());
    assertTrue(resp.getBody().contains("Running Shoes"), resp.getBody());
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=RecommendationControllerIT`
Expected: FAIL — 404 (no controller) / `RecommendationController` does not exist.

- [ ] **Step 3: Write `RecommendationController.java`**

```java
package com.arcadedb.examples.springcluster.recommendation;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

@RestController
@RequestMapping("/api/recommendations")
public class RecommendationController {

  private final RecommendationService service;

  public RecommendationController(RecommendationService service) {
    this.service = service;
  }

  @GetMapping("/collaborative/{userId}")
  public List<Map<String, Object>> collaborative(@PathVariable String userId) {
    return service.collaborative(userId);
  }

  @GetMapping("/similar/{productName}")
  public List<Map<String, Object>> similar(@PathVariable String productName) {
    return service.similarProducts(productName);
  }

  @GetMapping("/trending")
  public List<Map<String, Object>> trending() {
    return service.trending();
  }

  @GetMapping("/shows/{userId}")
  public List<Map<String, Object>> shows(@PathVariable String userId) {
    return service.shows(userId);
  }

  @GetMapping("/category/{category}/{userId}")
  public List<Map<String, Object>> category(@PathVariable String category, @PathVariable String userId) {
    return service.category(category, userId);
  }

  @GetMapping("/hybrid/{userId}")
  public Map<String, Object> hybrid(@PathVariable String userId) {
    return service.hybrid(userId);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=RecommendationControllerIT`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/recommendation/RecommendationController.java \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/recommendation/RecommendationControllerIT.java
git commit -m "feat(spring-cluster): expose recommendation queries over REST"
```

---

### Task 8: Cluster status and health endpoints

**Files:**
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/cluster/ClusterController.java`
- Create: `spring-cluster/src/main/java/com/arcadedb/examples/springcluster/cluster/HealthController.java`
- Test: `spring-cluster/src/test/java/com/arcadedb/examples/springcluster/cluster/ClusterEndpointsIT.java`

**Interfaces:**
- Consumes: `EmbeddedArcadeDbServer`, `EmbeddedServerProperties`.
- Produces:
  - `GET /api/cluster/status` → `{node, leader (bool), leaderName, configuredServers}`.
  - `GET /api/health` → 200 `{status:"UP", node}` when running + DB present, else 503 `{status:"DOWN", ...}`.

- [ ] **Step 1: Write the failing test**

`.../cluster/ClusterEndpointsIT.java`:
```java
package com.arcadedb.examples.springcluster.cluster;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
        "arcadedb.node-name=app-0",
        "arcadedb.server-list=app-0:12438:12484",
        "arcadedb.raft-port=12438",
        "arcadedb.http-port=12484",
        "arcadedb.data-path=target/it-arcadedb/task8"
    })
class ClusterEndpointsIT {

  @Autowired TestRestTemplate rest;

  @Test
  void statusReportsThisNodeAsLeader() {
    ResponseEntity<String> resp = rest.getForEntity("/api/cluster/status", String.class);
    assertEquals(HttpStatus.OK, resp.getStatusCode());
    assertTrue(resp.getBody().contains("\"node\":\"app-0\""), resp.getBody());
    assertTrue(resp.getBody().contains("\"leader\":true"), resp.getBody());
  }

  @Test
  void healthIsUp() {
    ResponseEntity<String> resp = rest.getForEntity("/api/health", String.class);
    assertEquals(HttpStatus.OK, resp.getStatusCode());
    assertTrue(resp.getBody().contains("\"status\":\"UP\""), resp.getBody());
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd spring-cluster && mvn -q test -Dtest=ClusterEndpointsIT`
Expected: FAIL — endpoints 404 / classes do not exist.

- [ ] **Step 3: Write `ClusterController.java`**

```java
package com.arcadedb.examples.springcluster.cluster;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.server.HAServerPlugin;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/cluster")
public class ClusterController {

  private final EmbeddedArcadeDbServer embedded;

  public ClusterController(EmbeddedArcadeDbServer embedded) {
    this.embedded = embedded;
  }

  @GetMapping("/status")
  public Map<String, Object> status() {
    HAServerPlugin ha = embedded.server().getHA();
    Map<String, Object> body = new LinkedHashMap<>();
    body.put("node", embedded.server().getServerName());
    body.put("leader", ha != null && ha.isLeader());
    body.put("leaderName", ha != null ? ha.getLeaderName() : null);
    body.put("configuredServers", ha != null ? ha.getConfiguredServers() : 0);
    return body;
  }
}
```

- [ ] **Step 4: Write `HealthController.java`**

```java
package com.arcadedb.examples.springcluster.cluster;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class HealthController {

  private final EmbeddedArcadeDbServer embedded;
  private final EmbeddedServerProperties props;

  public HealthController(EmbeddedArcadeDbServer embedded, EmbeddedServerProperties props) {
    this.embedded = embedded;
    this.props = props;
  }

  @GetMapping("/api/health")
  public ResponseEntity<Map<String, Object>> health() {
    boolean up = embedded.isRunning() && databaseReachable();
    Map<String, Object> body = new LinkedHashMap<>();
    body.put("status", up ? "UP" : "DOWN");
    body.put("node", embedded.server() != null ? embedded.server().getServerName() : "unknown");
    return up ? ResponseEntity.ok(body) : ResponseEntity.status(503).body(body);
  }

  private boolean databaseReachable() {
    try {
      return embedded.server().getDatabaseNames().contains(props.getDatabaseName());
    } catch (Exception e) {
      return false;
    }
  }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd spring-cluster && mvn -q test -Dtest=ClusterEndpointsIT`
Expected: PASS.

- [ ] **Step 6: Run the full test suite**

Run: `cd spring-cluster && mvn -q test`
Expected: PASS — all tests from Tasks 1-8.

- [ ] **Step 7: Commit**

```bash
git add spring-cluster/src/main/java/com/arcadedb/examples/springcluster/cluster \
        spring-cluster/src/test/java/com/arcadedb/examples/springcluster/cluster
git commit -m "feat(spring-cluster): add cluster status and health endpoints"
```

---

### Task 9: Dockerfile

**Files:**
- Create: `spring-cluster/Dockerfile`

**Interfaces:**
- Produces: an image that builds the fat jar and runs it on JRE 25, with `curl` available for
  the compose healthcheck. Exposes `8080` (REST), `2480` (ArcadeDB HTTP), `2434` (Raft).

- [ ] **Step 1: Write `Dockerfile`**

`spring-cluster/Dockerfile`:
```dockerfile
# syntax=docker/dockerfile:1

FROM maven:3.9-eclipse-temurin-25 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

FROM eclipse-temurin:25-jre
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/target/spring-cluster.jar app.jar
EXPOSE 8080 2480 2434
ENTRYPOINT ["java", "-jar", "app.jar"]
```

> If the `maven:3.9-eclipse-temurin-25` tag does not exist yet, use the newest
> `maven:*-eclipse-temurin-25` tag from Docker Hub (the JDK must be 25 to compile `release` 25).

- [ ] **Step 2: Build the image**

Run: `docker build -t spring-cluster:test spring-cluster`
Expected: build succeeds; final line `naming to docker.io/library/spring-cluster:test`.

- [ ] **Step 3: Smoke-test a single container**

Run:
```bash
docker run -d --name sc-smoke \
  -e NODE_NAME=app-0 \
  -e HA_SERVER_LIST=app-0:2434:2480 \
  -e ARCADEDB_DATA_PATH=/app/data \
  -p 18080:8080 spring-cluster:test
# wait for health
for i in $(seq 1 30); do curl -sf http://localhost:18080/api/health && break; sleep 2; done
```
Expected: JSON `{"status":"UP","node":"app-0"}`.

- [ ] **Step 4: Tear down the smoke container**

Run: `docker rm -f sc-smoke`
Expected: container removed.

- [ ] **Step 5: Commit**

```bash
git add spring-cluster/Dockerfile
git commit -m "feat(spring-cluster): add multi-stage Dockerfile on temurin 25"
```

---

### Task 10: Docker Compose cluster + scripts

**Files:**
- Create: `spring-cluster/docker-compose.yml`
- Create: `spring-cluster/start.sh`
- Create: `spring-cluster/test.sh`

**Interfaces:**
- Produces: a 3-node cluster (`app-0/1/2`), `start.sh` that brings it up and waits for one
  leader, `test.sh` that asserts replication and the expected top recommendation.

- [ ] **Step 1: Write `docker-compose.yml`**

`spring-cluster/docker-compose.yml`:
```yaml
services:
  app-0:
    build: .
    image: arcadedb-spring-cluster
    container_name: app-0
    environment:
      NODE_NAME: app-0
      HA_SERVER_LIST: "app-0:2434:2480,app-1:2434:2480,app-2:2434:2480"
      ARCADEDB_PASS: arcadedb
      ARCADEDB_DATA_PATH: /app/data
    ports:
      - "8080:8080"
    volumes:
      - app0-data:/app/data
    networks:
      - arcadedb-cluster
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/api/health"]
      interval: 5s
      timeout: 3s
      retries: 30

  app-1:
    build: .
    image: arcadedb-spring-cluster
    container_name: app-1
    environment:
      NODE_NAME: app-1
      HA_SERVER_LIST: "app-0:2434:2480,app-1:2434:2480,app-2:2434:2480"
      ARCADEDB_PASS: arcadedb
      ARCADEDB_DATA_PATH: /app/data
    ports:
      - "8081:8080"
    volumes:
      - app1-data:/app/data
    networks:
      - arcadedb-cluster
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/api/health"]
      interval: 5s
      timeout: 3s
      retries: 30

  app-2:
    build: .
    image: arcadedb-spring-cluster
    container_name: app-2
    environment:
      NODE_NAME: app-2
      HA_SERVER_LIST: "app-0:2434:2480,app-1:2434:2480,app-2:2434:2480"
      ARCADEDB_PASS: arcadedb
      ARCADEDB_DATA_PATH: /app/data
    ports:
      - "8082:8080"
    volumes:
      - app2-data:/app/data
    networks:
      - arcadedb-cluster
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8080/api/health"]
      interval: 5s
      timeout: 3s
      retries: 30

volumes:
  app0-data:
  app1-data:
  app2-data:

networks:
  arcadedb-cluster:
```

- [ ] **Step 2: Write `start.sh`**

`spring-cluster/start.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building and starting 3-node spring-cluster..."
docker compose up -d --build

nodes=("http://localhost:8080" "http://localhost:8081" "http://localhost:8082")

echo "Waiting for nodes to become healthy..."
for url in "${nodes[@]}"; do
  for i in $(seq 1 60); do
    if curl -sf "$url/api/health" >/dev/null 2>&1; then
      echo "  $url is healthy"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "Timeout waiting for $url" >&2
      exit 1
    fi
    sleep 2
  done
done

echo "Waiting for a single leader to be elected..."
for i in $(seq 1 30); do
  leaders=0
  for url in "${nodes[@]}"; do
    if [ "$(curl -sf "$url/api/cluster/status" | jq -r '.leader')" = "true" ]; then
      leaders=$((leaders + 1))
    fi
  done
  if [ "$leaders" -eq 1 ]; then
    echo "Cluster is up with one leader."
    exit 0
  fi
  sleep 2
done

echo "No single leader elected within timeout" >&2
exit 1
```

- [ ] **Step 3: Write `test.sh`**

`spring-cluster/test.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

n0="http://localhost:8080"
n1="http://localhost:8081"
n2="http://localhost:8082"

echo "Check 1: exactly one leader"
leaders=0
for url in "$n0" "$n1" "$n2"; do
  if [ "$(curl -sf "$url/api/cluster/status" | jq -r '.leader')" = "true" ]; then
    leaders=$((leaders + 1))
  fi
done
if [ "$leaders" -ne 1 ]; then
  echo "  FAIL: expected 1 leader, found $leaders" >&2
  exit 1
fi
echo "  PASS: exactly one leader"

echo "Check 2: identical collaborative reads across all nodes (replication)"
r0=$(curl -sf "$n0/api/recommendations/collaborative/u1" | jq -S .)
r1=$(curl -sf "$n1/api/recommendations/collaborative/u1" | jq -S .)
r2=$(curl -sf "$n2/api/recommendations/collaborative/u1" | jq -S .)
if [ "$r0" != "$r1" ] || [ "$r1" != "$r2" ]; then
  echo "  FAIL: reads differ across nodes" >&2
  exit 1
fi
echo "  PASS: identical reads on all 3 nodes"

echo "Check 3: top recommendation for u1 is Running Shoes"
top=$(echo "$r0" | jq -r '.[0].name')
if [ "$top" != "Running Shoes" ]; then
  echo "  FAIL: expected 'Running Shoes', got '$top'" >&2
  exit 1
fi
echo "  PASS: top recommendation is Running Shoes"

echo "All cluster checks passed."
```

- [ ] **Step 4: Make scripts executable**

Run: `chmod +x spring-cluster/start.sh spring-cluster/test.sh`
Expected: no output.

- [ ] **Step 5: Bring up the cluster**

Run: `./spring-cluster/start.sh`
Expected: ends with `Cluster is up with one leader.`

- [ ] **Step 6: Run the cluster test**

Run: `./spring-cluster/test.sh`
Expected: three `PASS` lines, then `All cluster checks passed.`

> If reads differ (Check 2) because data has not replicated yet, the followers are serving before
> replication completes — add a short retry in `test.sh` Check 2, or confirm the leader bootstrap
> committed. If the database is missing on a follower, confirm the ArcadeDB HTTP port `2480` is
> reachable between containers (write forwarding / replication channel).

- [ ] **Step 7: Tear down**

Run: `cd spring-cluster && docker compose down -v`
Expected: containers, network, and volumes removed.

- [ ] **Step 8: Commit**

```bash
git add spring-cluster/docker-compose.yml spring-cluster/start.sh spring-cluster/test.sh
git commit -m "feat(spring-cluster): add docker compose cluster with start and test scripts"
```

---

### Task 11: Documentation

**Files:**
- Create: `spring-cluster/README.md`
- Modify: `README.md` (root scenario table)

**Interfaces:**
- Produces: module README and a new row in the root table. No code.

- [ ] **Step 1: Write `spring-cluster/README.md`**

`spring-cluster/README.md`:
```markdown
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

- Server names must follow `<prefix>-<integer>` (`app-0`); ArcadeDB Raft uses the numeric
  suffix to identify peers.
- ArcadeDB Studio is excluded from the build; this scenario is API-only.
- Targets ArcadeDB 26.6.1, Spring Boot 3.5.x, Java 25.
```

- [ ] **Step 2: Add a row to the root `README.md` table**

In `README.md`, the Scenarios table currently ends with the Kubernetes row:
```
| [Kubernetes](./kubernetes/) | 3-node HA cluster deployed via Helm on a local kind cluster | Kubernetes / Helm |
```
Add immediately after it:
```
| [Spring Cluster](./spring-cluster/) | 3-node embedded ArcadeDB HA cluster inside Spring Boot apps, serving the recommendation engine over REST | Docker Compose |
```

- [ ] **Step 3: Update the root Prerequisites note (if needed)**

Confirm the root `README.md` Prerequisites mention `Docker`, `Docker Compose`, `curl`, `jq`
(already present). Add `JDK 25 + Maven 3.9+ (spring-cluster local builds)` to the list.

- [ ] **Step 4: Commit**

```bash
git add spring-cluster/README.md README.md
git commit -m "docs(spring-cluster): add scenario README and root table entry"
```

---

### Task 12: CI workflow + Dependabot

**Files:**
- Create: `.github/workflows/spring-cluster.yml`
- Modify: `.github/dependabot.yml`

**Interfaces:**
- Produces: a CI job mirroring `ha-cluster.yml` that runs `start.sh` + `test.sh`, and Dependabot
  coverage for the new module's Maven, Docker, and docker-compose manifests.

- [ ] **Step 1: Write `.github/workflows/spring-cluster.yml`**

```yaml
name: Spring Cluster CI

on:
  workflow_dispatch:
  push:
    paths:
      - spring-cluster/**
      - .github/workflows/spring-cluster.yml
  pull_request:
    paths:
      - spring-cluster/**
      - .github/workflows/spring-cluster.yml

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Checkout
        uses: actions/checkout@df4cb1c069e1874edd31b4311f1884172cec0e10 # v6.0.3
        with:
          fetch-depth: 1

      - name: Start spring-cluster
        run: ./spring-cluster/start.sh

      - name: Test spring-cluster
        run: ./spring-cluster/test.sh

      - name: Tear down
        if: always()
        working-directory: spring-cluster
        run: docker compose down -v
```

> Match the `actions/checkout` pinned SHA to whatever the sibling workflows currently use
> (copy the exact `uses:` line from `.github/workflows/ha-cluster.yml` at implementation time).

- [ ] **Step 2: Extend `.github/dependabot.yml`**

Append these three entries under `updates:` (keep the existing entries unchanged):
```yaml
  - package-ecosystem: "maven"
    directory: "/spring-cluster"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"

  - package-ecosystem: "docker"
    directory: "/spring-cluster"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"

  - package-ecosystem: "docker-compose"
    directory: "/spring-cluster"
    schedule:
      interval: "weekly"
    labels:
      - "dependencies"
```

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/dependabot.yml')); yaml.safe_load(open('.github/workflows/spring-cluster.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/spring-cluster.yml .github/dependabot.yml
git commit -m "ci(spring-cluster): add CI workflow and dependabot coverage"
```

---

## Self-Review

**Spec coverage:**
- §1 goal / placement → Task 11 (root table row, module README).
- §2 architecture (3 nodes, leader seed, any-node read) → Tasks 3, 5, 10.
- §3 module layout → File Structure + Tasks 1-12.
- §4 embedded lifecycle (config keys, HTTP enabled, server names, lazy DB) → Task 3.
- §5 leader bootstrap (idempotent, leader-only) → Task 5.
- §6 REST API (all 6 queries + cluster status + health) → Tasks 6, 7, 8.
- §7 Docker/scripts → Tasks 9, 10.
- §8 CI + §8.1 Dependabot → Task 12.
- §9 versions/minimal deps (Java 25, ArcadeDB 26.6.1, Spring Boot 3.5.x, studio excluded, no actuator) → Task 1, Global Constraints.
- §10 out of scope → respected (no Spring Data, no auth, no UI).
- §11 risks (HA_SERVER_LIST format, follower DB resolution, election timing, studio exclusion, inter-node HTTP) → called out inline in Tasks 3, 5, 10.

**Placeholder scan:** No TBD/TODO. The only conditional note is the Task 1 ordering of
`@EnableConfigurationProperties` relative to Task 2 — both paths give complete code. Docker base
image / checkout SHA notes point to exact verification commands, not placeholders.

**Type consistency:** `EmbeddedArcadeDbServer.server()/isLeader()/database()/isRunning()` used
consistently in Tasks 5-8. `RecommendationService` method names match between Task 6 (definitions)
and Task 7 (controller calls). `EmbeddedServerProperties` getters match usage in Tasks 3, 5, 6, 8.
Endpoint paths match between Task 7/8 controllers and Task 10 `test.sh` / Task 11 README.
