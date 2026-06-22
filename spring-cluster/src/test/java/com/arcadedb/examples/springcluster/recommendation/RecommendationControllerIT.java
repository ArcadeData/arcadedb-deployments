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
        "arcadedb.node-name=localhost",
        "arcadedb.server-list=localhost:12437:12483",
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
