package com.arcadedb.examples.springcluster;

import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.EnableConfigurationProperties;

@SpringBootApplication
@EnableConfigurationProperties(EmbeddedServerProperties.class)
public class SpringClusterApplication {

  public static void main(String[] args) {
    SpringApplication.run(SpringClusterApplication.class, args);
  }
}
