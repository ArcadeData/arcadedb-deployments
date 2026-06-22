package com.arcadedb.examples.springcluster.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "arcadedb")
public class EmbeddedServerProperties {

  private String nodeName = "app-0";
  private String serverList = "app-0:2434:2480";
  private String rootPassword = "arcadedb";
  private String databaseName = "RecommendationEngine";
  private String dataPath = "./target/arcadedb";
  private int httpPort = 2480;
  private int raftPort = 2434;

  public String getNodeName() { return nodeName; }
  public void setNodeName(String nodeName) { this.nodeName = nodeName; }

  public String getServerList() { return serverList; }
  public void setServerList(String serverList) { this.serverList = serverList; }

  public String getRootPassword() { return rootPassword; }
  public void setRootPassword(String rootPassword) { this.rootPassword = rootPassword; }

  public String getDatabaseName() { return databaseName; }
  public void setDatabaseName(String databaseName) { this.databaseName = databaseName; }

  public String getDataPath() { return dataPath; }
  public void setDataPath(String dataPath) { this.dataPath = dataPath; }

  public int getHttpPort() { return httpPort; }
  public void setHttpPort(int httpPort) { this.httpPort = httpPort; }

  public int getRaftPort() { return raftPort; }
  public void setRaftPort(int raftPort) { this.raftPort = raftPort; }
}
