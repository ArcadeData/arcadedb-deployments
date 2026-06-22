package com.arcadedb.examples.springcluster.recommendation;

import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.NoSuchElementException;

@RestController
@RequestMapping("/api/recommendations")
public class RecommendationController {

  private final RecommendationService service;

  public RecommendationController(RecommendationService service) {
    this.service = service;
  }

  @GetMapping("/collaborative/{userId}")
  public List<Map<String, Object>> collaborative(@PathVariable String userId) {
    return service.collaborative(userId);
  }

  @GetMapping("/similar/{productName}")
  public List<Map<String, Object>> similar(@PathVariable String productName) {
    return service.similarProducts(productName);
  }

  @GetMapping("/trending")
  public List<Map<String, Object>> trending() {
    return service.trending();
  }

  @GetMapping("/shows/{userId}")
  public List<Map<String, Object>> shows(@PathVariable String userId) {
    return service.shows(userId);
  }

  @GetMapping("/category/{category}/{userId}")
  public List<Map<String, Object>> category(@PathVariable String category, @PathVariable String userId) {
    return service.category(category, userId);
  }

  @GetMapping("/hybrid/{userId}")
  public Map<String, Object> hybrid(@PathVariable String userId) {
    return service.hybrid(userId);
  }

  /** A missing user/product (no stored embedding or rows) maps to 404 rather than 500. */
  @ExceptionHandler(NoSuchElementException.class)
  @ResponseStatus(HttpStatus.NOT_FOUND)
  public Map<String, String> handleNotFound(NoSuchElementException ex) {
    return Map.of("error", ex.getMessage());
  }
}
