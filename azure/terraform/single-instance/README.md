# Terraform — ArcadeDB Single Instance (Azure)

Deploys a single ArcadeDB VM on Azure from the ArcadeDB Azure Marketplace image. The AWS counterpart is `../../../aws/terraform/single-instance`.

## What gets created

- a Linux VM (Trusted launch, SSH key login only, encrypted OS disk, boot diagnostics on managed storage) from the Marketplace image, or from your Compute Gallery image when `image_id` is set;
- a network interface in your subnet with a network security group: the ArcadeDB HTTP port from `allowed_cidr`, and SSH from `allowed_cidr` when `enable_ssh = true`;
- optionally (`public_ip = true`) a Standard static public IP.

The resource group and the subnet must already exist. Everything is tagged with `tags`, `Cluster = <name_prefix>` and `Application = ArcadeDB`.

## How it is configured

The VM gets a cloud-init file that:

- when `arcadedb_root_password` is set, writes it to `/etc/arcadedb/root-password` (mode 0600, owner `arcadedb`). The image's first-boot service sees the file and keeps it instead of generating a password. The password is never a `-D` option, so it does not show in `ps`. It is still stored in the VM's custom data, so change it after the first login;
- writes a systemd override with `ARCADEDB_SETTINGS` (root password file, database and backup directories, server mode, HTTP port, plugins, `arcadedb_java_opts`) and `JAVA_OPTS` (`-Xms512m -Xmx<arcadedb_max_ram>m -XX:+UseG1GC`);
- restarts ArcadeDB, so the settings apply whatever order the image's units started in.

With no `arcadedb_root_password` the image generates a unique password on first boot. Read it over SSH (`enable_ssh = true`) from `~/arcadedb-root-password.txt` of `admin_username`, or with `sudo cat /etc/arcadedb/root-password`.

The root password may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -`.

## Prerequisites

- Terraform >= 1.5 and the Azure CLI, logged in (`az login`) with a subscription selected (or `ARM_SUBSCRIPTION_ID` set)
- An existing resource group and subnet
- An SSH key pair
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
| arcadedb_root_password | No       | _(empty)_  | Root password; empty keeps the image's per-VM password |
| arcadedb_server_mode   | No       | production | Server mode (`development`, `test`, `production`) |
| arcadedb_http_port     | No       | 2480       | HTTP port for API and Studio |
| arcadedb_plugins       | No       | _(empty)_  | Comma-separated plugin list |
| arcadedb_max_ram       | No       | 2048       | Max heap size in MB (`-Xmx`) |
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

Not yet.

## Destroying

```bash
terraform destroy
```
