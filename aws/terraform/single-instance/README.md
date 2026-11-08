# Terraform — ArcadeDB Single Instance

Deploys a single ArcadeDB instance on AWS, equivalent to the CloudFormation template in `../../cloudformation/single-instance.yaml`.

## Prerequisites

- Terraform >= 1.0
- An ArcadeDB AMI: an active AWS Marketplace subscription to the ArcadeDB listing (set `marketplace_product_code`), or provide `ami_id` directly
- An existing VPC and subnet; optionally an EC2 key pair for SSH access

## Quick Start

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values

terraform init
terraform plan
terraform apply
```

## AMI Lookup

If `ami_id` is left empty (the default), Terraform finds the most recent AMI whose architecture matches `instance_type` (arm64 for `t4g`, `m7g`, `r7g`, `c7g`; x86_64 otherwise):

- by default, AMIs in your own account whose name contains `arcadedb`;
- with `marketplace_product_code` set, the AWS Marketplace AMI of that product (use the code of the listing that matches `instance_type`):

  | Architecture | Product code |
  |--------------|--------------|
  | x86_64 | `a8ux0w7t0kz9iam85pf4lgoa9` |
  | arm64 | `7i9pstc6vwgjehw76ou7xa1wa` |

To use a specific AMI, set `ami_id` in your tfvars. The instance requires IMDSv2.

Allowed instance types: `t3.{medium,large,xlarge}`, `{m6i,m7i,r6i,r7i,c6i,c7i}.{large,xlarge,2xlarge,4xlarge}` (x86_64) and `t4g.{medium,large,xlarge}`, `{m7g,r7g,c7g}.{large,xlarge,2xlarge,4xlarge}` (arm64).

The root password may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -`, with at least one lowercase, uppercase, digit and special character. It is stored in the instance user data, so change it after the first login.

## Variables

**Instance & Network:**

| Variable            | Required | Default      | Description                |
|---------------------|----------|--------------|----------------------------|
| instance_type       | No       | m6i.large    | EC2 instance type (must match the AMI architecture) |
| key_name            | No       | _(empty)_    | SSH key pair name; empty launches without SSH key access |
| vpc_id              | Yes      | -            | VPC ID                     |
| subnet_id           | Yes      | -            | Subnet ID                  |
| allowed_cidr        | No       | 10.0.0.0/16  | CIDR for access            |
| volume_size         | No       | 20           | EBS volume size (GB)       |
| volume_type         | No       | gp3          | EBS volume type            |
| enable_encryption   | No       | true         | Enable EBS encryption      |

**ArcadeDB Configuration:**

| Variable               | Required | Default    | Description                                          |
|------------------------|----------|------------|------------------------------------------------------|
| arcadedb_root_password | Yes      | -          | Root password                                        |
| arcadedb_server_mode   | No       | production | Server mode (`development`, `test`, `production`)    |
| arcadedb_http_port     | No       | 2480       | HTTP port for API and Studio                         |
| arcadedb_plugins       | No       | _(empty)_  | Comma-separated plugin list                          |
| arcadedb_max_ram       | No       | 2048       | Max heap size in MB (`-Xmx`)                         |
| arcadedb_java_opts     | No       | _(empty)_  | Additional `-Darcadedb.*` JVM flags (appended as-is) |
| ami_id                 | No       | _(auto)_   | ArcadeDB AMI ID (auto-detected if empty)             |
| marketplace_product_code | No     | _(empty)_  | Look up the Marketplace AMI of this product instead of your own AMIs |

## Outputs

| Output            | Description              |
|-------------------|--------------------------|
| instance_id       | EC2 instance ID          |
| public_ip         | Public IP address        |
| private_ip        | Private IP address       |
| studio_url        | ArcadeDB Studio URL      |
| api_url           | ArcadeDB API URL         |
| security_group_id | Security group ID        |
| ssh_command       | SSH connection command    |

## Destroying

```bash
terraform destroy
```
