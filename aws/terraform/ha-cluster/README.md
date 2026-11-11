# Terraform — ArcadeDB 3-Node HA Cluster

Deploys a 3-node ArcadeDB cluster (Raft) on AWS: one EC2 instance per Availability Zone, node discovery through a Route 53 private hosted zone, and an optional internal Network Load Balancer in front of the HTTP API.

> This example is validated statically (`terraform fmt`, `validate`) in this repository, which has no AWS account. It was deployed on AWS on 2026-11-08 and again on 2026-11-11, after the fixed network interfaces (one ENI per node, Elastic IPs for `associate_public_ip`) were added (default VPC of `us-east-1`, `t3.large` nodes). Both runs passed the checks listed under "Verified on AWS" below. Items marked "unverified" are not covered by those runs.

## What gets created

| Resource | Count | Notes |
|----------|-------|-------|
| `aws_network_interface` | 3 | primary ENI of node N in `subnet_ids[N]`, with the node security group; created before the instance, so the node's private IP is fixed and survives instance replacement |
| `aws_eip` | 0 or 3 | only with `associate_public_ip = true`, one per ENI |
| `aws_instance` | 3 | `node-0`, `node-1`, `node-2`, each on its own ENI; IMDSv2 required, encrypted gp3 root volume, no public IP by default |
| `aws_security_group` | 1 | shared by the nodes (see [Network access](#network-access)) |
| `aws_route53_zone` | 1 | private zone (default `arcadedb.internal`) attached to `vpc_id` |
| `aws_route53_record` | 3 | `node-N.<zone>` A record → private IP of node N's ENI |
| `aws_lb` (network, internal) + target group + listener + 3 attachments | 0 or 1 | only with `enable_nlb = true` (default) |

Every resource that supports tags is tagged `Cluster = <name_prefix>` (provider `default_tags`) and gets its own `Name` tag (e.g. `arcadedb-ha-node-0`). No IAM role or instance profile is created.

## How the cluster is configured

Each node's user data writes the same systemd override as the single-instance example (`ARCADEDB_SETTINGS`), plus the HA settings:

```
-Darcadedb.server.name=node-<N>
-Darcadedb.ha.enabled=true
-Darcadedb.ha.serverList=node-0.arcadedb.internal:2434:2480,node-1.arcadedb.internal:2434:2480,node-2.arcadedb.internal:2434:2480
-Darcadedb.ha.replicationFactor=3
-Darcadedb.server.readinessRequiresHA=true
```

The server name must be `node-<0-based index>`: ArcadeDB Raft uses the numeric suffix as an index into the server list. Raft uses port 2434, the HTTP API port 2480 (`arcadedb_http_port`). The user data is identical on all nodes except for the server name.

Each node runs on a network interface created before the instance, so its private IP is known up front. Terraform creates the ENIs, then the A records, then the instances, so all three peer names already resolve when a node boots: there is no wait for DNS, and a node does not depend on the other instances being up. Nodes boot in parallel.

Raft replication and elections never go through the NLB: every node connects to its peers directly on port 2434, using the `node-N.<private_zone_name>` names from the server list. The NLB only carries client HTTP traffic, so its health-check timing and connection handling cannot affect consensus.

The NLB health check is `GET /api/v1/ready` (unauthenticated). With `readinessRequiresHA=true` a node only reports ready once it has joined the cluster, so only cluster members receive traffic. Followers forward writes to the leader, so any node can take a request (a write through the NLB succeeded in the test run).

## Prerequisites

- Terraform >= 1.2, AWS provider >= 6.10 (`primary_network_interface`).
- A VPC with **DNS support and DNS hostnames enabled** (`enableDnsSupport` and `enableDnsHostnames`). Without them the private hosted zone does not resolve and the nodes cannot find each other.
- **Three subnets in that VPC, each in a different Availability Zone.** The plan fails if two subnets share an AZ or a subnet is outside `vpc_id`.
- No other private hosted zone with the same name (`private_zone_name`) associated with the VPC, and no other load balancer or target group named `<name_prefix>-nlb` / `<name_prefix>-tg` in the region: for a second cluster in the same VPC use a distinct `private_zone_name` and a distinct `name_prefix`.
- An ArcadeDB AMI:
  - **AWS Marketplace:** subscribe to the ArcadeDB listing in the Marketplace console first (launching an unsubscribed Marketplace AMI fails), then set `marketplace_product_code` to the code matching `instance_type`:

    | Architecture | Product code |
    |--------------|--------------|
    | x86_64 | `a8ux0w7t0kz9iam85pf4lgoa9` |
    | arm64 | `7i9pstc6vwgjehw76ou7xa1wa` |

  - or set `ami_id` directly;
  - or leave both empty to use the most recent AMI in your own account whose name contains `arcadedb`.

  The lookup picks the AMI matching the architecture of `instance_type` (arm64 for `t4g`, `m7g`, `r7g`, `c7g`; x86_64 otherwise). An explicit `ami_id` of the wrong architecture fails at plan time.
- IAM permissions for EC2 (including network interfaces, and Elastic IPs when `associate_public_ip = true`), Elastic Load Balancing and Route 53.
- With `associate_public_ip = true`: an internet gateway on the VPC and three free Elastic IPs in the region quota (5 per region by default). Creating the security group needs `ec2:RevokeSecurityGroupEgress` (the provider removes the default egress rule).

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: vpc_id, subnet_ids, arcadedb_root_password, AMI

terraform init
terraform plan
terraform apply
```

The cluster is reachable inside the VPC (or from networks routed into it, such as a VPN or peered VPC):

```bash
STUDIO=$(terraform output -raw studio_url)
curl -s "$STUDIO/api/v1/ready" -o /dev/null -w '%{http_code}\n'
curl -s -u root:<password> "$STUDIO/api/v1/server?mode=cluster"
```

`studio_url` points at the NLB, or at `node-0.<zone>` when `enable_nlb = false`. Node DNS names only resolve inside the VPC.

## Network access

| Port | Source | Purpose |
|------|--------|---------|
| 2434 | the node security group itself | Raft between nodes |
| 2480 | the node security group itself | HTTP between nodes |
| 2480 | `allowed_cidr` | clients (API and Studio), directly or through the NLB |
| 2480 | the three node subnets' CIDRs (only with `enable_nlb`) | NLB health checks, which come from the NLB's private IPs in those subnets |
| 22 | `allowed_cidr` (only when `key_name` is set) | SSH |

**`allowed_cidr` must cover the real clients.** The internal NLB keeps the client's source IP for instance targets, so the node security group sees the client address, not the NLB's. A client outside `allowed_cidr` is dropped even when it reaches the NLB.

Because client IPs are preserved, a node that calls the NLB can be routed back to itself and the connection times out. From a node, call the nodes by their own DNS names (`node-N.<private_zone_name>`) instead of the NLB.

`allowed_cidr` defaults to `10.0.0.0/16`, never `0.0.0.0/0`. Do not set it to `0.0.0.0/0`; especially not together with `associate_public_ip = true`, which would expose the API to the internet.

## Variables

**Cluster & Network:**

| Variable             | Required | Default           | Description |
|----------------------|----------|-------------------|-------------|
| vpc_id               | Yes      | -                 | VPC ID (DNS support and hostnames enabled) |
| subnet_ids           | Yes      | -                 | Exactly 3 subnet IDs in distinct AZs; node N goes in `subnet_ids[N]` |
| name_prefix          | No       | arcadedb-ha       | Resource name prefix; also the `Cluster` tag (1-24 chars) |
| private_zone_name    | No       | arcadedb.internal | Route 53 private hosted zone for node discovery |
| enable_nlb           | No       | true              | Create the internal NLB on the HTTP port |
| allowed_cidr         | No       | 10.0.0.0/16       | CIDR allowed to reach the HTTP API (and SSH) |
| associate_public_ip  | No       | false             | Give each node an Elastic IP (needs an internet gateway) |
| key_name             | No       | _(empty)_         | EC2 key pair; opens port 22 to `allowed_cidr` when set |
| iam_instance_profile | No       | _(empty)_         | Name of an existing IAM instance profile to attach to the nodes (this example creates no IAM resources) |

**Instances & Storage:**

| Variable          | Required | Default   | Description |
|-------------------|----------|-----------|-------------|
| instance_type     | No       | m6i.large | EC2 instance type for all nodes (must match the AMI architecture) |
| volume_size       | No       | 20        | Root volume size per node (GB) |
| volume_type       | No       | gp3       | EBS volume type |
| enable_encryption | No       | true      | Encrypt the root volumes |
| ami_id            | No       | _(auto)_  | ArcadeDB AMI ID (looked up if empty) |
| marketplace_product_code | No | _(empty)_ | Look up the Marketplace AMI of this product instead of your own AMIs |
| arcadedb_version  | No       | 26.11.1   | Informational `Version` tag |

Allowed instance types: `t3.{medium,large,xlarge}`, `{m6i,m7i,r6i,r7i,c6i,c7i}.{large,xlarge,2xlarge,4xlarge}` (x86_64) and `t4g.{medium,large,xlarge}`, `{m7g,r7g,c7g}.{large,xlarge,2xlarge,4xlarge}` (arm64).

**ArcadeDB Configuration:**

| Variable               | Required | Default    | Description |
|------------------------|----------|------------|-------------|
| arcadedb_root_password | Yes      | -          | Root password, the same on every node |
| arcadedb_server_mode   | No       | production | Server mode (`development`, `test`, `production`) |
| arcadedb_http_port     | No       | 2480       | HTTP port for API and Studio (also used in the server list and by the NLB) |
| arcadedb_plugins       | No       | _(empty)_  | Comma-separated plugin list |
| arcadedb_max_ram       | No       | 2048       | Max heap size in MB (`-Xmx`) |
| arcadedb_java_opts     | No       | _(empty)_  | Additional `-Darcadedb.*` JVM flags (appended as-is on every node) |

The root password may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -`, with at least one lowercase, uppercase, digit and special character. It ends up in the instance user data and in the Terraform state; protect the state and change the password after the first login.

To reach the nodes without SSH, set `iam_instance_profile` to an existing instance profile that grants `AmazonSSMManagedInstanceCore` and open a shell with SSM Session Manager (`aws ssm start-session --target <instance-id>`); the nodes need a route to the SSM endpoints (NAT gateway or VPC endpoints).

## Outputs

| Output            | Description |
|-------------------|-------------|
| nlb_dns_name      | Internal NLB DNS name (`null` when `enable_nlb = false`) |
| instance_ids      | Instance IDs of node-0..node-2 |
| private_ips       | Private IPs of node-0..node-2 (fixed, from the ENIs) |
| network_interface_ids | Primary ENI IDs of node-0..node-2 |
| public_ips        | Elastic IPs of node-0..node-2 (empty without `associate_public_ip`) |
| node_dns_names    | `node-N.<zone>` names of node-0..node-2 |
| studio_url        | Studio URL: NLB, or node-0 when the NLB is disabled |
| zone_name         | Private hosted zone name |
| zone_id           | Private hosted zone ID |
| security_group_id | Node security group ID |

## Cost

This runs three instances, three EBS volumes, an NLB and a hosted zone around the clock. As a rough order of magnitude with the defaults, at on-demand us-east-1 prices: 3 × `m6i.large` (about $0.096/hour each), plus the NLB (about $0.0225/hour plus capacity units), plus 3 × 20 GB gp3, plus $0.50/month for the hosted zone: in the region of $230/month before data transfer and any Marketplace software charge. Cross-AZ traffic (Raft replication, cross-zone load balancing) is billed as data transfer. Check the AWS Pricing Calculator for your region, and destroy the cluster when you are done.

## Verified on AWS

Two deployments (Terraform, default VPC of `us-east-1`, `t3.large` nodes, public IPs on so the test could reach the nodes through SSM) passed these checks, then were destroyed without leftovers: one on 2026-11-08, and one on 2026-11-11 with the fixed network interfaces and Elastic IPs:

- the three nodes formed one cluster with one leader;
- a record written through node-0 was readable on all three nodes;
- a write through the NLB succeeded and was readable afterwards;
- after stopping the leader, a surviving node became leader and writes still succeeded.

Not covered by those runs: replacing a node, changing user data on a running cluster, restoring from a backup, and sustained load. After the leader was stopped, the surviving nodes still reported three members, because a stopped node stays in the configured Raft peer set.

## Operations notes

- **Replacing a node:** `terraform apply -replace='aws_instance.node[0]'`. Terraform destroys the old instance before it creates the new one, which frees the ENI for it. The replacement attaches the same network interface, so it keeps the node's private IP and A record, and the other nodes need no DNS or configuration change. The new instance starts with an empty root volume (see the next point).
- **Data on replacement:** the databases and the Raft log live on the root volume, which is deleted with the instance. A replaced node rejoins with no data and has to catch up from the leader, so the time a replacement takes grows with the database size. Until it has caught up, only two nodes hold the data. Replace one node at a time and wait until the new one answers `/api/v1/ready` before touching the next. How ArcadeDB brings an empty node up to date (snapshot or log replay) and how long that takes is **unverified** for these templates. A separate EBS data volume that survives replacement is not part of this example.
- **Changing user data** (password, settings) on an existing cluster: Terraform updates `user_data` in place, which stops and starts the instance, but the script only runs on first boot. Recreate the nodes (`terraform apply -replace='aws_instance.node[0]'`, one at a time) or change the systemd override on the hosts.
- The cluster keeps working with one node down (2 of 3 form a Raft majority); with two nodes down it stops accepting writes.

## Destroying

```bash
terraform destroy
```

This deletes the instances, their root volumes, the network interfaces and the Elastic IPs, so **all data is lost**. Take a backup first if you need it. The hosted zone is deleted together with its three records; if you added records to the zone by hand, delete them first or the zone deletion fails.
