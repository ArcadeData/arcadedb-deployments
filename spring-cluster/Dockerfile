# syntax=docker/dockerfile:1

FROM maven:3-eclipse-temurin-26 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

FROM eclipse-temurin:25-jre
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /build/target/spring-cluster.jar app.jar
EXPOSE 8080 2480 2434
ENTRYPOINT ["java", "-jar", "app.jar"]
