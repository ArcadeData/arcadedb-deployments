package com.arcadedb.examples.springcluster.cluster;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
public class HealthController {

  private final EmbeddedArcadeDbServer embedded;
  private final EmbeddedServerProperties props;

  public HealthController(EmbeddedArcadeDbServer embedded, EmbeddedServerProperties props) {
    this.embedded = embedded;
    this.props = props;
  }

  @GetMapping("/api/health")
  public ResponseEntity<Map<String, Object>> health() {
    boolean up = embedded.isRunning() && databaseReachable();
    Map<String, Object> body = new LinkedHashMap<>();
    body.put("status", up ? "UP" : "DOWN");
    body.put("node", embedded.server() != null ? embedded.server().getServerName() : "unknown");
    return up ? ResponseEntity.ok(body) : ResponseEntity.status(503).body(body);
  }

  private boolean databaseReachable() {
    try {
      return embedded.server().getDatabaseNames().contains(props.getDatabaseName());
    } catch (Exception e) {
      return false;
    }
  }
}
