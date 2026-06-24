package com.arcadedb.examples.springcluster.cluster;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.web.servlet.client.RestTestClient;

// Tests use 'localhost' (not app-0) because the new Ratis Raft needs a DNS-resolvable host; production compose uses Docker-resolvable app-0/1/2.
@SpringBootTest(
    webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
    properties = {
        "arcadedb.node-name=localhost",
        "arcadedb.server-list=localhost:12438:12484",
        "arcadedb.raft-port=12438",
        "arcadedb.http-port=12484",
        "arcadedb.data-path=target/it-arcadedb/task8"
    })
class ClusterEndpointsIT {

  @LocalServerPort int port;
  RestTestClient rest;

  @BeforeEach
  void setUp() {
    rest = RestTestClient.bindToServer().baseUrl("http://localhost:" + port).build();
  }

  @Test
  void statusReportsThisNodeAsLeader() {
    rest.get().uri("/api/cluster/status")
        .exchange()
        .expectStatus().isOk()
        .expectBody()
        .jsonPath("$.node").isEqualTo("localhost")
        .jsonPath("$.leader").isEqualTo(true);
  }

  @Test
  void healthIsUp() {
    rest.get().uri("/api/health")
        .exchange()
        .expectStatus().isOk()
        .expectBody()
        .jsonPath("$.status").isEqualTo("UP");
  }
}
