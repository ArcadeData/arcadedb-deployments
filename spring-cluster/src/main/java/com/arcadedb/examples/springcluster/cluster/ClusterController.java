package com.arcadedb.examples.springcluster.cluster;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.server.HAServerPlugin;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.LinkedHashMap;
import java.util.Map;

@RestController
@RequestMapping("/api/cluster")
public class ClusterController {

  private final EmbeddedArcadeDbServer embedded;

  public ClusterController(EmbeddedArcadeDbServer embedded) {
    this.embedded = embedded;
  }

  @GetMapping("/status")
  public Map<String, Object> status() {
    HAServerPlugin ha = embedded.server().getHA();
    Map<String, Object> body = new LinkedHashMap<>();
    body.put("node", embedded.server().getServerName());
    body.put("leader", ha != null && ha.isLeader());
    body.put("leaderName", ha != null ? ha.getLeaderName() : null);
    body.put("configuredServers", ha != null ? ha.getConfiguredServers() : 0);
    return body;
  }
}
