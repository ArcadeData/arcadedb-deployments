package com.arcadedb.examples.springcluster.recommendation;

import com.arcadedb.examples.springcluster.config.EmbeddedArcadeDbServer;
import com.arcadedb.examples.springcluster.config.EmbeddedServerProperties;
import com.arcadedb.query.sql.executor.Result;
import com.arcadedb.query.sql.executor.ResultSet;
import com.arcadedb.server.ServerDatabase;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;
import java.util.stream.Collectors;

@Service
public class RecommendationService {

  private final EmbeddedArcadeDbServer embedded;
  private final EmbeddedServerProperties props;

  public RecommendationService(EmbeddedArcadeDbServer embedded, EmbeddedServerProperties props) {
    this.embedded = embedded;
    this.props = props;
  }

  private ServerDatabase db() {
    return embedded.server().getDatabase(props.getDatabaseName());
  }

  // Q1 — collaborative filtering (graph)
  public List<Map<String, Object>> collaborative(String userId) {
    String cypher = """
        MATCH (me:User {id: $uid})-[:PURCHASED]->(p:Product)
              <-[:PURCHASED]-(other:User)-[:PURCHASED]->(rec:Product)
        WHERE rec <> p AND NOT (me)-[:PURCHASED]->(rec)
        RETURN rec.name AS name, rec.category AS category, count(DISTINCT other) AS score
        ORDER BY score DESC LIMIT 20""";
    return rows(db().query("cypher", cypher, Map.of("uid", userId)));
  }

  // Q2 — vector similarity to a product's embedding
  public List<Map<String, Object>> similarProducts(String productName) {
    List<Double> embedding = embeddingOf("Product", "name", productName);
    String sql = "SELECT name, category, price FROM Product WHERE inStock = true "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 20) DESC "
        + "LIMIT 20";
    return rows(db().query("sql", sql));
  }

  // Q3 — trending (time-series)
  public List<Map<String, Object>> trending() {
    String sql = "SELECT productId, sum(purchaseCount) AS totalInteractions "
        + "FROM ProductInteraction GROUP BY productId ORDER BY totalInteractions DESC LIMIT 10";
    return rows(db().query("sql", sql));
  }

  // Q4 — streaming collaborative (graph, SQL MATCH)
  public List<Map<String, Object>> shows(String userId) {
    String sql = "SELECT title, genre, count(*) AS collab_score FROM ( "
        + "MATCH {type: User, where: (id = :uid)}"
        + ".out('WATCHED'){as: show}"
        + ".in('WATCHED'){as: viewer, where: (id != :uid)}"
        + ".out('WATCHED'){as: rec, where: ($matched.show != @this)} "
        + "RETURN rec.title AS title, rec.genre AS genre "
        + ") GROUP BY title, genre ORDER BY collab_score DESC LIMIT 10";
    return rows(db().query("sql", sql, Map.of("uid", userId)));
  }

  // Q5 — personalized category page (vector)
  public List<Map<String, Object>> category(String category, String userId) {
    List<Double> embedding = embeddingOf("User", "id", userId);
    String sql = "SELECT name, category, price FROM Product "
        + "WHERE category = :cat AND inStock = true "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 30) DESC "
        + "LIMIT 30";
    return rows(db().query("sql", sql, Map.of("cat", category)));
  }

  // Q6 — hybrid multi-model (graph + vector + time-series)
  public Map<String, Object> hybrid(String userId) {
    Map<String, Object> out = new LinkedHashMap<>();

    String candidateCypher = """
        MATCH (me:User {id: $uid})-[:PURCHASED]->(p:Product)
              <-[:PURCHASED]-(other:User)-[:PURCHASED]->(rec:Product)
        WHERE rec <> p AND NOT (me)-[:PURCHASED]->(rec)
        RETURN DISTINCT rec.name AS name""";
    List<Map<String, Object>> candidates = rows(db().query("cypher", candidateCypher, Map.of("uid", userId)));
    out.put("candidates", candidates);

    if (candidates.isEmpty()) {
      out.put("ranked", List.of());
      out.put("trending", List.of());
      return out;
    }

    String inList = candidates.stream()
        .map(r -> "'" + String.valueOf(r.get("name")).replace("'", "''") + "'")
        .collect(Collectors.joining(", "));
    List<Double> embedding = embeddingOf("User", "id", userId);

    String rankedSql = "SELECT name, category, price FROM Product WHERE name IN [" + inList + "] "
        + "ORDER BY vectorNeighbors('Product[embedding]', " + formatVector(embedding) + ", 10) DESC";
    out.put("ranked", rows(db().query("sql", rankedSql)));

    String trendingSql = "SELECT productId, sum(purchaseCount) AS trending_score "
        + "FROM ProductInteraction WHERE productId IN [" + inList + "] "
        + "GROUP BY productId ORDER BY trending_score DESC";
    out.put("trending", rows(db().query("sql", trendingSql)));

    return out;
  }

  private List<Double> embeddingOf(String type, String keyProp, String keyValue) {
    String sql = "SELECT embedding FROM " + type + " WHERE " + keyProp + " = :k LIMIT 1";
    try (ResultSet rs = db().query("sql", sql, Map.of("k", keyValue))) {
      if (rs.hasNext()) {
        List<?> raw = rs.next().getProperty("embedding");
        return raw.stream().map(v -> ((Number) v).doubleValue()).collect(Collectors.toList());
      }
    }
    throw new NoSuchElementException(type + " '" + keyValue + "' not found");
  }

  private static String formatVector(List<Double> vector) {
    return vector.stream().map(String::valueOf).collect(Collectors.joining(",", "[", "]"));
  }

  private static List<Map<String, Object>> rows(ResultSet rs) {
    List<Map<String, Object>> out = new ArrayList<>();
    try (rs) {
      while (rs.hasNext()) {
        Result r = rs.next();
        Map<String, Object> row = new LinkedHashMap<>();
        for (String name : r.getPropertyNames()) {
          row.put(name, r.getProperty(name));
        }
        out.add(row);
      }
    }
    return out;
  }
}
