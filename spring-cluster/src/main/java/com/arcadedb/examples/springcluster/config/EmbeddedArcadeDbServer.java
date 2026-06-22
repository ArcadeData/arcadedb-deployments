package com.arcadedb.examples.springcluster.config;

import com.arcadedb.ContextConfiguration;
import com.arcadedb.GlobalConfiguration;
import com.arcadedb.server.ArcadeDBServer;
import com.arcadedb.server.ServerDatabase;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

@Component
public class EmbeddedArcadeDbServer implements SmartLifecycle {

  private static final Logger log = LoggerFactory.getLogger(EmbeddedArcadeDbServer.class);

  private final EmbeddedServerProperties props;
  private volatile ArcadeDBServer server;
  private volatile boolean running;

  public EmbeddedArcadeDbServer(EmbeddedServerProperties props) {
    this.props = props;
  }

  @Override
  public void start() {
    ContextConfiguration cfg = new ContextConfiguration();
    cfg.setValue(GlobalConfiguration.SERVER_NAME, props.getNodeName());
    cfg.setValue(GlobalConfiguration.SERVER_ROOT_PATH, props.getDataPath());
    cfg.setValue(GlobalConfiguration.SERVER_DATABASE_DIRECTORY, props.getDataPath() + "/databases");
    cfg.setValue(GlobalConfiguration.SERVER_ROOT_PASSWORD, props.getRootPassword());
    cfg.setValue(GlobalConfiguration.SERVER_HTTP_INCOMING_PORT, props.getHttpPort());
    cfg.setValue(GlobalConfiguration.HA_ENABLED, true);
    cfg.setValue(GlobalConfiguration.HA_SERVER_LIST, props.getServerList());
    cfg.setValue(GlobalConfiguration.HA_RAFT_PORT, props.getRaftPort());
    cfg.setValue(GlobalConfiguration.HA_QUORUM, "majority");
    cfg.setValue(GlobalConfiguration.HA_CLUSTER_NAME, "arcadedb");

    server = new ArcadeDBServer(cfg);
    server.start();
    running = true;
    log.info("Embedded ArcadeDB server '{}' started (raft={}, http={})",
        props.getNodeName(), props.getRaftPort(), props.getHttpPort());
  }

  @Override
  public void stop() {
    if (server != null && server.isStarted()) {
      server.stop();
    }
    running = false;
  }

  @Override
  public boolean isRunning() {
    return running;
  }

  public ArcadeDBServer server() {
    return server;
  }

  public boolean isLeader() {
    return server != null && server.getHA() != null && server.getHA().isLeader();
  }

  public ServerDatabase database() {
    return server.getDatabase(props.getDatabaseName());
  }
}
