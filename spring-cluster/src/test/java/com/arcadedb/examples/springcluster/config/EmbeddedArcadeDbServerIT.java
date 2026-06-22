package com.arcadedb.examples.springcluster.config;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;

import java.time.Duration;
import java.time.Instant;

import static org.junit.jupiter.api.Assertions.assertTrue;

// Tests use 'localhost' (not app-0) because the new Ratis Raft needs a DNS-resolvable host; production compose uses Docker-resolvable app-0/1/2.
@SpringBootTest(properties = {
    "arcadedb.node-name=localhost",
    "arcadedb.server-list=localhost:12434:12480",
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
