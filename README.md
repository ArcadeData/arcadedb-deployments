# ArcadeDB Deployment Scenarios

A collection of ready-to-run deployment configurations for ArcadeDB,
from single-node development setups to production-grade HA clusters.

## Scenarios

| Scenario | Description | Orchestrator |
|----------|-------------|--------------|
| [HA Cluster](./ha-cluster/) | 3-node high-availability cluster with Raft consensus | Docker Compose |
| [Kubernetes](./kubernetes/) | 3-node HA cluster deployed via Helm on a local kind cluster | Kubernetes / Helm |
| [Spring Cluster](./spring-cluster/) | 3-node embedded ArcadeDB HA cluster inside Spring Boot apps, serving the recommendation engine over REST | Docker Compose |

## Prerequisites

- Docker >= 24.0
- Docker Compose >= 2.0 (ha-cluster and spring-cluster scenarios)
- [kind](https://kind.sigs.k8s.io/) >= 0.24.0, [Helm](https://helm.sh/) >= 3.16, `kubectl` (kubernetes scenario)
- JDK 25 and Maven 3.9+ (spring-cluster local builds)
- `curl` and `jq`

## Quick Start

Each scenario directory contains:
- `start.sh` — bring the deployment up
- `stop.sh` — tear the deployment down (kubernetes scenario)
- `test.sh` — verify the deployment is working
- `README.md` — scenario-specific details and configuration options
