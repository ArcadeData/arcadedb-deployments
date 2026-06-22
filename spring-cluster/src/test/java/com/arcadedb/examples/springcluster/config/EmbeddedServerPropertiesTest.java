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
