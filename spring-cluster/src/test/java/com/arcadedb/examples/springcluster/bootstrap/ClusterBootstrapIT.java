package com.arcadedb.examples.springcluster.bootstrap;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import com.arcadedb.server.ServerDatabase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.test.context.SpringBootTest;

import static org.junit.jupiter.api.Assertions.assertEquals;

// Tests use 'localhost' (not app-0) because the new Ratis Raft needs a DNS-resolvable host; production compose uses Docker-resolvable app-0/1/2.
@SpringBootTest(properties = {
    "arcadedb.node-name=localhost",
    "arcadedb.server-list=localhost:12435:12481",
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
    assertEquals(5, db.countType("Show", false));
  }
}
