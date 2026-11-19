# Terraform — ArcadeDB 3-Node HA Cluster (Azure)

Deploys a 3-node ArcadeDB cluster (Raft) on Azure from the ArcadeDB Azure Marketplace image: one VM per availability zone, node discovery through an Azure private DNS zone, and an optional internal Standard load balancer in front of the HTTP API. The AWS counterpart is `../../../aws/terraform/ha-cluster`.

> This template is validated statically (`terraform fmt`, `validate`) and with `terraform test` against a mocked provider in this repository, which has no Azure subscription. It was deployed on Azure on 2026-11-19 by the `terraform-ha-test.yml` workflow of [ArcadeData/arcadedb-azure](https://github.com/ArcadeData/arcadedb-azure); see "Verified on Azure" below.

## What gets created

| Resource | Count | Notes |
|----------|-------|-------|
| `azurerm_network_interface` | 3 | NIC of node N in `subnet_id`, static private IP (`private_ips[N]`, default `cidrhost(<subnet prefix>, 10 + N)`); created before the VM, so the IP is fixed and survives VM replacement |
| `azurerm_linux_virtual_machine` | 3 | `<name_prefix>-node-0..2`, node N in zone `availability_zones[N]`; Trusted launch, SSH key login only, encrypted managed OS disk, boot diagnostics on managed storage, no public IP |
| `azurerm_application_security_group` | 1 | groups the three NICs, used by the node-to-node rules |
| `azurerm_network_security_group` + rules | 1 | attached to each NIC (see [Network access](#network-access)) |
| `azurerm_private_dns_zone` | 1 | private zone (default `arcadedb.internal`) |
| `azurerm_private_dns_zone_virtual_network_link` | 1 | links the zone to the subnet's VNet, auto-registration off |
| `azurerm_private_dns_a_record` | 3 | `node-N.<zone>` → static IP of node N's NIC |
| `azurerm_lb` (Standard, internal) + backend pool + probe + rule + 3 pool associations | 0 or 1 | only with `enable_lb = true` (default); zone-redundant frontend IP in `subnet_id` |

The resource group and the subnet must already exist. Every resource that takes tags is tagged with `tags`, `Cluster = <name_prefix>` and `Application = ArcadeDB`. No managed identity or role assignment is created.

## How the cluster is configured

Each node's cloud-init writes the same files as the single-instance template: the root password to `/etc/arcadedb/root-password` (mode 0600, owner `arcadedb`, read through `arcadedb.server.rootPasswordPath`, never a `-D` option) and a systemd override with `ARCADEDB_SETTINGS` and `JAVA_OPTS`. The settings add the HA options:

```
-Darcadedb.server.name=node-<N>
-Darcadedb.ha.enabled=true
-Darcadedb.ha.serverList=node-0.arcadedb.internal:2434:2480,node-1.arcadedb.internal:2434:2480,node-2.arcadedb.internal:2434:2480
-Darcadedb.ha.replicationFactor=3
-Darcadedb.server.readinessRequiresHA=true
```

The server name must be `node-<0-based index>`: ArcadeDB Raft uses the numeric suffix as an index into the server list. Raft uses port 2434, the HTTP API port 2480 (`arcadedb_http_port`). The custom data is identical on all nodes except for the server name. Cloud-init then restarts ArcadeDB so the settings apply whatever order the image's units started in.

Each node's NIC has a static private IP, so its address is known up front. Terraform creates the NICs, then the A records and the VNet link, then the VMs, so all three peer names already resolve when a node boots: there is no wait for DNS, and a node does not depend on the other VMs being up. Nodes boot in parallel.

Raft replication and elections never go through the load balancer: every node connects to its peers directly on port 2434, using the `node-N.<private_zone_name>` names from the server list. The load balancer only carries client HTTP traffic.

The load balancer probe is a TCP check on the HTTP port, every 5 seconds, 2 probes: a node gets traffic once ArcadeDB listens. An HTTP probe on `/api/v1/ready` is not possible because that endpoint answers 204 and Azure Load Balancer counts only 200 as healthy. Followers forward writes to the leader, so any node can take a request; a node that is still joining the cluster answers with an error until it has joined.

## Prerequisites

- Terraform >= 1.5 and the Azure CLI, logged in (`az login`) with a subscription selected (or `ARM_SUBSCRIPTION_ID` set).
- An existing resource group and subnet. The subnet needs three free addresses for the nodes (by default `.10`, `.11`, `.12` of its prefix; set `private_ips` if those are taken) and one for the load balancer.
- A region with availability zones, and a `vm_size` offered in all three (`az vm list-skus --location <region> --size <size> --query '[].locationInfo[].zones'`). Otherwise set `availability_zones`.
- vCPU quota for three VMs of `vm_size` in the region (6 vCPU for the default `Standard_D2s_v5`, DSv5 family).
- No other private DNS zone with the same name (`private_zone_name`) linked to the VNet: a VNet cannot link two zones with the same name. For a second cluster in the same VNet use a distinct `private_zone_name` and a distinct `name_prefix`.
- An SSH key pair.
- Outbound internet access, if the nodes need it (OS security updates, `defaultDatabases` imports from URLs, plugins). The nodes have no public IP and sit behind an internal Standard load balancer, which gives no outbound path, and new VNets default to private subnets, so attach a NAT gateway (or route through a firewall) on the subnet.
- For the Marketplace image, accept the terms once per subscription, for the architecture you deploy:

  ```bash
  az vm image terms accept --urn arcadedb:arcadedb:arcadedb-ubuntu:latest         # x64
  az vm image terms accept --urn arcadedb:arcadedb:arcadedb-ubuntu-arm64:latest   # Arm64
  ```

  The offer has a paid plan with a 1-month free trial. With `image_id` set, no terms are needed.

The architecture follows `vm_size`: Arm64 sizes (`Standard_D2ps_v5`, `Standard_D4pds_v5`, `Standard_E2ps_v5`, ...) get the `arcadedb-ubuntu-arm64` image, all others `arcadedb-ubuntu`. With `image_id`, the plan fails if the gallery image definition's architecture does not match `vm_size`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: resource_group_name, subnet_id, admin_ssh_public_key, allowed_cidr, arcadedb_root_password

terraform init
terraform plan
terraform apply
```

The cluster is reachable inside the VNet (or from networks routed into it, such as a VPN or peered VNet):

```bash
STUDIO=$(terraform output -raw studio_url)
curl -s "$STUDIO/api/v1/ready" -o /dev/null -w '%{http_code}\n'
curl -s -u root:<password> "$STUDIO/api/v1/server?mode=cluster"
```

`studio_url` points at the load balancer's private IP, or at `node-0.<zone>` when `enable_lb = false`. Node DNS names only resolve inside the linked VNet.

## Network access

| Port | Source | Destination | Purpose |
|------|--------|-------------|---------|
| 2434 | the nodes' application security group | the nodes' application security group | Raft between nodes |
| 2480 | the nodes' application security group | the nodes' application security group | HTTP between nodes |
| 2480 | `allowed_cidr` | any | clients (API and Studio), directly or through the load balancer |
| 22 | `allowed_cidr` (only with `enable_ssh = true`) | any | SSH |

Azure's default NSG rules also allow the load balancer probe (`AzureLoadBalancer`) and all traffic inside the VNet, unless a subnet NSG or a higher-priority rule of yours denies it; the explicit node rules above keep Raft working in that case.

**`allowed_cidr` must cover the real clients.** The internal load balancer keeps the client's source IP, so the NSG sees the client address, not the load balancer's.

**Clients of the load balancer must be other VMs, not the nodes.** A VM that calls an internal Standard load balancer frontend whose backend pool contains that same VM times out when the flow lands on itself (with three nodes, about one call in three). From a node, call the nodes by their DNS names (`node-N.<private_zone_name>`) instead.

Do not set `allowed_cidr` to `0.0.0.0/0`. The nodes get no public IP.

## Variables

**Placement & Cluster:**

| Variable             | Required | Default             | Description |
|----------------------|----------|---------------------|-------------|
| resource_group_name  | Yes      | -                   | Existing resource group |
| location             | No       | _(RG location)_     | Azure region |
| name_prefix          | No       | arcadedb-ha         | Prefix for resource names and the `Cluster` tag |
| availability_zones   | No       | `["1","2","3"]`     | Zone of node-0, node-1, node-2 |
| private_zone_name    | No       | arcadedb.internal   | Private DNS zone for node discovery |
| enable_lb            | No       | true                | Create the internal Standard load balancer on the HTTP port |
| tags                 | No       | `{}`                | Extra tags for all resources |

**Network:**

| Variable     | Required | Default   | Description |
|--------------|----------|-----------|-------------|
| subnet_id    | Yes      | -         | Existing subnet for the nodes and the load balancer; its VNet is linked to the zone |
| private_ips  | No       | `[]`      | Static IPs of node-0..2 (empty: `cidrhost(<subnet prefix>, 10 + N)`) |
| allowed_cidr | Yes      | -         | CIDR allowed to reach ArcadeDB (and SSH) |
| enable_ssh   | No       | false     | Open port 22 to `allowed_cidr` |

**VMs & Image:**

| Variable             | Required | Default           | Description |
|----------------------|----------|-------------------|-------------|
| vm_size              | No       | Standard_D2s_v5   | VM size for all nodes (decides the architecture) |
| admin_username       | No       | azureuser         | Admin user (SSH key only) |
| admin_ssh_public_key | Yes      | -                 | SSH public key |
| os_disk_size_gb      | No       | 30                | OS disk size per node (GB) |
| os_disk_type         | No       | Premium_LRS       | OS disk storage type |
| image_id             | No       | _(empty)_         | Compute Gallery image version ID, instead of the Marketplace image |
| image_version        | No       | latest            | Marketplace image version |

**ArcadeDB Configuration:**

| Variable               | Required | Default    | Description |
|------------------------|----------|------------|-------------|
| arcadedb_root_password | Yes      | -          | Root password (8+ characters), the same on every node |
| arcadedb_server_mode   | No       | production | Server mode (`development`, `test`, `production`) |
| arcadedb_http_port     | No       | 2480       | HTTP port for API and Studio (also used in the server list and by the load balancer) |
| arcadedb_plugins       | No       | _(empty)_  | Comma-separated plugin list |
| arcadedb_max_ram       | No       | 2048       | Max heap size in MB, a whole number without unit (`-Xmx`) |
| arcadedb_java_opts     | No       | _(empty)_  | Additional `-Darcadedb.*` JVM flags (appended as-is on every node, avoid double quotes) |

The root password must be at least 8 characters (ArcadeDB refuses to start with a shorter one) and may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -`. It ends up in the VMs' custom data and in the Terraform state; protect the state and change the password after the first login.

## Outputs

| Output         | Description |
|----------------|-------------|
| lb_private_ip  | Private IP of the internal load balancer (`null` when `enable_lb = false`) |
| vm_ids         | VM resource IDs of node-0..node-2 |
| vm_names       | VM names of node-0..node-2 |
| private_ips    | Static private IPs of node-0..node-2 |
| node_dns_names | `node-N.<zone>` names of node-0..node-2 |
| studio_url     | Studio URL: load balancer, or node-0 when the load balancer is disabled |
| zone_name      | Private DNS zone name |
| nsg_id         | Network security group ID of the nodes |

## Tests

```bash
terraform init -backend=false
terraform test
```

The tests run `plan` against a mocked provider, so they need no Azure credentials.

## Verified on Azure

On 2026-11-19 one deployment (Terraform, `eastus`, `Standard_D2s_v4` nodes in zones 1/2/3, ArcadeDB 26.11.1 from the Compute Gallery image that the Marketplace offer is built from, internal load balancer on) passed these checks, then was destroyed without leftovers:

- the three nodes formed one cluster and agreed on one leader;
- a record written on a follower was readable on all three nodes;
- a write and a read through the internal load balancer, from a separate VM in the same VNet, succeeded;
- after stopping the leader VM, a surviving node became leader and a write on it was readable on the other survivor.

Not covered by that run: the Marketplace image itself (`image_id` empty), Arm64 nodes, replacing a node, changing `custom_data` on a running cluster, restoring from a backup, and sustained load.

## Operations notes

- **Replacing a node:** `terraform apply -replace='azurerm_linux_virtual_machine.node[0]'`. The replacement uses the same NIC, so it keeps the node's private IP and A record, and the other nodes need no DNS or configuration change. The new VM starts with an empty OS disk (see the next point).
- **Data on replacement:** the databases and the Raft log live on the OS disk, which is deleted with the VM. A replaced node rejoins with no data and catches up from the leader. Replace one node at a time and wait until the new one answers `/api/v1/ready` before touching the next. A separate data disk that survives replacement is not part of this template.
- **Changing custom data** (password, settings) on an existing cluster replaces the VMs, because Azure cannot change custom data in place. Replace them one at a time (`-replace`, as above) or change the systemd override on the hosts instead.
- The cluster keeps working with one node down (2 of 3 form a Raft majority); with two nodes down it stops accepting writes.

## Destroying

```bash
terraform destroy
```

This deletes the VMs and their OS disks, so **all data is lost**. Take a backup first if you need it. The private DNS zone is deleted together with its records; if you added records to the zone by hand, delete them first.
