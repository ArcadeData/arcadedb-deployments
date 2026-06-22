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
    "arcadedb.node-name=localhost",
    "arcadedb.server-list=localhost:12436:12482",
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
