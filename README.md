# ArcadeDB Deployment Scenarios

A collection of ready-to-run deployment configurations for ArcadeDB,
from single-node development setups to production-grade HA clusters.

## Scenarios

| Scenario | Description | Orchestrator |
|----------|-------------|--------------|
| [HA Cluster](./ha-cluster/) | 3-node high-availability cluster with Raft consensus | Docker Compose |

## Prerequisites

- Docker >= 24.0
- Docker Compose >= 2.0
- `curl` and `jq`

## Quick Start

Each scenario directory contains:
- `start.sh` — bring the deployment up
- `test.sh` — verify the deployment is working
- `README.md` — scenario-specific details and configuration options
