package com.arcadedb.examples.springcluster;

import org.junit.jupiter.api.Test;

class SpringClusterApplicationTests {

  @Test
  void mainClassExists() {
    // Compile-time proof the app entrypoint exists; full context load is exercised in Task 3+.
    org.junit.jupiter.api.Assertions.assertNotNull(SpringClusterApplication.class);
  }
}
