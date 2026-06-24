package com.arcadedb.examples.springcluster.recommendation;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.web.servlet.client.RestTestClient;

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

  @LocalServerPort int port;
  RestTestClient rest;

  @BeforeEach
  void setUp() {
    rest = RestTestClient.bindToServer().baseUrl("http://localhost:" + port).build();
  }

  @Test
  void collaborativeEndpointReturnsRunningShoes() {
    rest.get().uri("/api/recommendations/collaborative/u1")
        .exchange()
        .expectStatus().isOk()
        .expectBody(String.class).value(body -> assertTrue(body.contains("Running Shoes"), body));
  }

  @Test
  void trendingEndpointReturnsOk() {
    rest.get().uri("/api/recommendations/trending")
        .exchange()
        .expectStatus().isOk()
        .expectBody(String.class).value(body -> assertTrue(body.contains("Running Shoes"), body));
  }

  @Test
  void unknownProductReturnsNotFound() {
    rest.get().uri("/api/recommendations/similar/NoSuchProduct")
        .exchange()
        .expectStatus().isNotFound();
  }
}
