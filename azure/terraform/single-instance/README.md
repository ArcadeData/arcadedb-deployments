# Terraform — ArcadeDB Single Instance (Azure)

Deploys a single ArcadeDB VM on Azure from the ArcadeDB Azure Marketplace image. The AWS counterpart is `../../../aws/terraform/single-instance`.

## What gets created

- a Linux VM (Trusted launch, SSH key login only, encrypted OS disk, boot diagnostics on managed storage) from the Marketplace image, or from your Compute Gallery image when `image_id` is set;
- a network interface in your subnet with a network security group: the ArcadeDB HTTP port from `allowed_cidr`, and SSH from `allowed_cidr` when `enable_ssh = true`;
- optionally (`public_ip = true`) a Standard static public IP.

The resource group and the subnet must already exist. Every resource that takes tags is tagged with `tags`, `Cluster = <name_prefix>` and `Application = ArcadeDB` (the OS disk is not tagged).

## How it is configured

The VM gets a cloud-init file that:

- when `arcadedb_root_password` is set, writes it to `/etc/arcadedb/root-password` (mode 0600, owner `arcadedb`). The image's first-boot service sees the file and keeps it instead of generating a password. The password is never a `-D` option, so it does not show in `ps`. It is still stored in the VM's custom data, so change it after the first login;
- writes a systemd override with `ARCADEDB_SETTINGS` (root password file, database and backup directories, server mode, HTTP port, plugins, `arcadedb_java_opts`) and `JAVA_OPTS` (`-Xms512m -Xmx<arcadedb_max_ram>m -XX:+UseG1GC`);
- restarts ArcadeDB, so the settings apply whatever order the image's units started in.

With no `arcadedb_root_password` the image generates a unique password on first boot. Read it over SSH (`enable_ssh = true`) from `~/arcadedb-root-password.txt` of `admin_username`, or with `sudo cat /etc/arcadedb/root-password`. The VM has no public IP unless `public_ip = true`, so SSH needs a machine inside the VNet (or a VPN, peering or Bastion). Without SSH, read it through the Azure control plane:

```bash
az vm run-command invoke -g <rg> -n <vm> --command-id RunShellScript --scripts 'cat /etc/arcadedb/root-password'
```

A root password you set must be at least 8 characters (ArcadeDB refuses to start with a shorter one) and may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -`.

## Prerequisites

- Terraform >= 1.5 and the Azure CLI, logged in (`az login`) with a subscription selected (or `ARM_SUBSCRIPTION_ID` set)
- An existing resource group and subnet
- An SSH key pair
- Outbound internet access, if the VM needs it (OS security updates, `defaultDatabases` imports from URLs such as the one in `terraform.tfvars.example`, plugins). Without `public_ip = true` the VM has no public outbound path by default, and new VNets default to private subnets, so attach a NAT gateway (or route through a firewall) on the subnet.
- For the Marketplace image, accept the terms once per subscription, for the architecture you deploy:

  ```bash
  az vm image terms accept --urn arcadedb:arcadedb:arcadedb-ubuntu:latest         # x64
  az vm image terms accept --urn arcadedb:arcadedb:arcadedb-ubuntu-arm64:latest   # Arm64
  ```

  The offer has a paid plan with a 1-month free trial. With `image_id` set, no terms are needed.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

Then open the `studio_url` output from a machine inside `allowed_cidr`, and log in as `root`.

Azure's default NSG rule `AllowVnetInBound` allows all traffic from inside the VNet (and from peered or VPN-connected networks), so `allowed_cidr` does not restrict sources inside the VNet; add a higher-priority deny rule or a subnet NSG if you need that.

The architecture follows `vm_size`: Arm64 sizes (`Standard_D2ps_v5`, `Standard_D4pds_v5`, `Standard_E2ps_v5`, ...) get the `arcadedb-ubuntu-arm64` image, all others `arcadedb-ubuntu`. With `image_id`, the plan fails if the gallery image definition's architecture does not match `vm_size`.

## Variables

**Placement & VM:**

| Variable             | Required | Default           | Description |
|----------------------|----------|-------------------|-------------|
| resource_group_name  | Yes      | -                 | Existing resource group |
| location             | No       | _(RG location)_   | Azure region |
| name_prefix          | No       | arcadedb          | Prefix for resource names and the `Cluster` tag |
| vm_size              | No       | Standard_D2s_v5   | VM size (decides the architecture) |
| admin_username       | No       | azureuser         | Admin user (SSH key only) |
| admin_ssh_public_key | Yes      | -                 | SSH public key |
| os_disk_size_gb      | No       | 30                | OS disk size (GB) |
| os_disk_type         | No       | Premium_LRS       | OS disk storage type |
| image_id             | No       | _(empty)_         | Compute Gallery image version ID, instead of the Marketplace image |
| image_version        | No       | latest            | Marketplace image version |
| tags                 | No       | `{}`              | Extra tags for all resources |

**Network:**

| Variable     | Required | Default   | Description |
|--------------|----------|-----------|-------------|
| subnet_id    | Yes      | -         | Existing subnet |
| allowed_cidr | Yes      | -         | CIDR allowed to reach ArcadeDB (and SSH) |
| enable_ssh   | No       | false     | Open port 22 to `allowed_cidr` |
| public_ip    | No       | false     | Attach a Standard static public IP |

**ArcadeDB Configuration:**

| Variable               | Required | Default    | Description |
|------------------------|----------|------------|-------------|
| arcadedb_root_password | No       | _(empty)_  | Root password (8+ characters); empty keeps the image's per-VM password |
| arcadedb_server_mode   | No       | production | Server mode (`development`, `test`, `production`) |
| arcadedb_http_port     | No       | 2480       | HTTP port for API and Studio |
| arcadedb_plugins       | No       | _(empty)_  | Comma-separated plugin list |
| arcadedb_max_ram       | No       | 2048       | Max heap size in MB, a whole number without unit (`-Xmx`) |
| arcadedb_java_opts     | No       | _(empty)_  | Additional `-Darcadedb.*` JVM flags (appended as-is, avoid double quotes) |

## Outputs

| Output             | Description |
|--------------------|-------------|
| vm_id              | VM resource ID |
| vm_name            | VM name |
| private_ip         | Private IP address |
| public_ip          | Public IP address (null without `public_ip`) |
| studio_url         | ArcadeDB Studio URL |
| admin_username     | Admin user for SSH |
| root_password_hint | Where to read the root password |

## Tests

```bash
terraform init -backend=false
terraform test
```

The tests run `plan` against a mocked provider, so they need no Azure credentials.

## Verified on Azure

On 2026-11-19 two deployments (Terraform, `eastus`, ArcadeDB 26.11.1 from the Compute Gallery image that the Marketplace offer is built from, root password set through `arcadedb_root_password`) passed these checks, then were destroyed without leftovers:

- x64 on `Standard_D2s_v5` (Trusted launch on) and Arm64 on `Standard_D2ps_v5` (Trusted launch off, the default for Arm64);
- ArcadeDB answered an authenticated `/api/v1/server` with the configured password;
- a database was created, a record inserted and read back.

Not covered by those runs: the Marketplace image itself (`image_id` empty), the image-generated password (`arcadedb_root_password` empty), `enable_ssh` and public IPs.

## Destroying

```bash
terraform destroy
```
