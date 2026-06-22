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
        "arcadedb.node-name=localhost",
        "arcadedb.server-list=localhost:12438:12484",
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
    assertTrue(resp.getBody().contains("\"node\":\"localhost\""), resp.getBody());
    assertTrue(resp.getBody().contains("\"leader\":true"), resp.getBody());
  }

  @Test
  void healthIsUp() {
    ResponseEntity<String> resp = rest.getForEntity("/api/health", String.class);
    assertEquals(HttpStatus.OK, resp.getStatusCode());
    assertTrue(resp.getBody().contains("\"status\":\"UP\""), resp.getBody());
  }
}
