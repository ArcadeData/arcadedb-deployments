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
      } catch (Exception e) {
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
    // Naive split: every ';' terminates a statement. Safe for our scripts (no ';' inside string literals or the LSM_VECTOR METADATA block).
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
