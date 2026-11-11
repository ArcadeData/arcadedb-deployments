# CloudFormation Templates

This directory contains AWS CloudFormation templates for deploying ArcadeDB.

## Important Prerequisites

### Choose the AMI

The template takes the AMI as the required `AmiId` parameter, so there is nothing to edit in it. Subscribe to the
ArcadeDB listing on AWS Marketplace first (the subscription is required to launch its AMI), then use the AMI ID
for the region you deploy to. Use an AMI from the same region you deploy to, and match it to the instance type:

| AMI | Instance types |
|-----|----------------|
| amd64 (x86_64) | `t3`, `m6i`, `m7i`, `r6i`, `r7i`, `c6i`, `c7i` |
| arm64 (Graviton) | `t4g`, `m7g`, `r7g`, `c7g` |

A mismatch (for example an arm64 AMI on `m6i.large`) fails at launch with an EC2 error. To find AMIs in your own account:

```bash
aws ec2 describe-images --owners self --filters "Name=name,Values=*arcadedb*" \
  --query 'Images[*].[ImageId,Name,Architecture]' --output table
```

The instance requires IMDSv2 (session tokens) through a launch template. The stack does not wait for ArcadeDB to
start: the image has no `cfn-signal`, so check `StudioURL` or `<ip>:2480/api/v1/ready` (HTTP 204) after creation.

## Security Considerations

### Password Security Limitation

**WARNING**: This template passes the root password to the EC2 instance via UserData. While the password parameter is marked with `NoEcho: true` to hide it in the CloudFormation console, it has important security limitations:

- The password may only contain `A-Z a-z 0-9 @ ! # ^ + = . _ & -` (with at least one lowercase, uppercase, digit and special character), because it is passed through the shell and systemd
- The password is visible in the UserData of the EC2 instance
- Anyone with EC2 describe permissions can retrieve the UserData (and therefore the password)
- The password is stored in the instance metadata service (accessible from within the instance)

**Best Practice for Production Environments:**

Use AWS Secrets Manager to securely store and retrieve the password:

1. **Store the password in Secrets Manager:**
   ```bash
   aws secretsmanager create-secret \
     --name arcadedb/root-password \
     --secret-string '{"password":"YourSecurePassword123!"}'
   ```

2. **Modify the template** to grant the IAM role access to Secrets Manager:
   ```yaml
   - PolicyName: SecretsManagerAccess
     PolicyDocument:
       Version: '2012-10-17'
       Statement:
         - Effect: Allow
           Action:
             - secretsmanager:GetSecretValue
           Resource: arn:aws:secretsmanager:*:*:secret:arcadedb/*
   ```

3. **Update UserData** to retrieve the password from Secrets Manager:
   ```bash
   PASSWORD=$(aws secretsmanager get-secret-value \
     --secret-id arcadedb/root-password \
     --query SecretString --output text | jq -r .password)
   ```

For more information, see:
- [AWS Secrets Manager Best Practices](https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html)
- [EC2 UserData Security Considerations](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html)

## Available Templates

### single-instance.yaml

Deploys a single ArcadeDB instance with:
- Configurable instance type, x86_64 or arm64 (Graviton)
- Security group with customizable CIDR access, or an existing one (`ExistingSecurityGroupId`)
- Optional EBS encryption
- CloudWatch monitoring
- Automatic recovery alarm
- IAM role for AWS service integration (optional, `CreateIamResources`)
- IMDSv2 required
- Tunable ArcadeDB settings (server mode, HTTP port, plugins, heap size)
- Escape-hatch parameter for arbitrary `-Darcadedb.*` JVM flags

Configuration is applied via a systemd drop-in override that sets `ARCADEDB_SETTINGS` and `JAVA_OPTS` environment variables, matching the canonical ArcadeDB configuration approach.

### ha-cluster.yaml

Deploys a 3-node ArcadeDB cluster (Raft), one instance per Availability Zone, with node discovery through a Route 53 private hosted zone and an optional internal Network Load Balancer. It is the CloudFormation counterpart of [`../terraform/ha-cluster`](../terraform/ha-cluster). See [HA cluster (ha-cluster.yaml)](#ha-cluster-ha-clusteryaml) below.

The sections from [Usage](#usage) to [Troubleshooting](#troubleshooting) describe `single-instance.yaml`.

## Usage

### Via AWS Console

1. Open AWS CloudFormation console
2. Click "Create Stack"
3. Upload `single-instance.yaml`
4. Fill in parameters
5. Click "Create Stack"

### Via AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name arcadedb-production \
  --template-body file://single-instance.yaml \
  --parameters \
    ParameterKey=AmiId,ParameterValue=ami-xxxxx \
    ParameterKey=InstanceType,ParameterValue=m6i.large \
    ParameterKey=KeyName,ParameterValue=my-key-pair \
    ParameterKey=VpcId,ParameterValue=vpc-xxxxx \
    ParameterKey=SubnetId,ParameterValue=subnet-xxxxx \
    ParameterKey=AllowedCIDR,ParameterValue=10.0.0.0/16 \
    ParameterKey=ArcadeDBRootPassword,ParameterValue='MySecurePass123!' \
    ParameterKey=ArcadeDBServerMode,ParameterValue=production \
    ParameterKey=ArcadeDBMaxRAM,ParameterValue=4096 \
  --capabilities CAPABILITY_IAM
```

### Via AWS SDK (Python)

```python
import boto3

client = boto3.client('cloudformation')

with open('single-instance.yaml', 'r') as f:
    template = f.read()

response = client.create_stack(
    StackName='arcadedb-production',
    TemplateBody=template,
    Parameters=[
        {'ParameterKey': 'AmiId', 'ParameterValue': 'ami-xxxxx'},
        {'ParameterKey': 'InstanceType', 'ParameterValue': 'm6i.large'},
        {'ParameterKey': 'KeyName', 'ParameterValue': 'my-key-pair'},
        {'ParameterKey': 'VpcId', 'ParameterValue': 'vpc-xxxxx'},
        {'ParameterKey': 'SubnetId', 'ParameterValue': 'subnet-xxxxx'},
        {'ParameterKey': 'AllowedCIDR', 'ParameterValue': '10.0.0.0/16'},
        {'ParameterKey': 'ArcadeDBRootPassword', 'ParameterValue': 'MySecurePass123!'},
        {'ParameterKey': 'ArcadeDBServerMode', 'ParameterValue': 'production'},
        {'ParameterKey': 'ArcadeDBMaxRAM', 'ParameterValue': '4096'},
    ],
    Capabilities=['CAPABILITY_IAM']
)
```

## Parameters

**Instance & Network:**

| Parameter            | Required | Default      | Description                |
|----------------------|----------|--------------|----------------------------|
| AmiId                | Yes      | -            | ArcadeDB AMI ID (amd64 or arm64) |
| InstanceType         | No       | m6i.large    | EC2 instance type (must match the AMI architecture) |
| KeyName              | No       | _(empty)_    | SSH key pair name; empty launches without SSH key access |
| CreateIamResources   | No       | true         | Create the IAM role, instance profile and recovery alarm |
| ExistingSecurityGroupId | No    | _(empty)_    | Use this security group instead of creating one |
| VpcId                | Yes      | -            | VPC ID                     |
| SubnetId             | Yes      | -            | Subnet ID                  |
| AllowedCIDR          | No       | 10.0.0.0/16  | CIDR for access (only when a security group is created) |
| VolumeSize           | No       | 20           | EBS volume size (GB)       |
| VolumeType           | No       | gp3          | EBS volume type            |
| EnableEncryption     | No       | true         | Enable EBS encryption      |

**ArcadeDB Configuration:**

| Parameter            | Required | Default      | Description                                              |
|----------------------|----------|--------------|----------------------------------------------------------|
| ArcadeDBRootPassword | Yes      | -            | Root password                                            |
| ArcadeDBServerMode   | No       | production   | Server mode (`development`, `test`, `production`)        |
| ArcadeDBHttpPort     | No       | 2480         | HTTP port for API and Studio                             |
| ArcadeDBPlugins      | No       | _(empty)_    | Comma-separated plugin list                              |
| ArcadeDBMaxRAM       | No       | 2048         | Max heap size in MB (`-Xmx`)                             |
| ArcadeDBJavaOpts     | No       | _(empty)_    | Additional `-Darcadedb.*` JVM flags (appended as-is)     |

## Outputs

| Output | Description |
|--------|-------------|
| InstanceId | EC2 instance ID |
| PublicIP | Public IP address |
| PrivateIP | Private IP address |
| StudioURL | ArcadeDB Studio URL |
| APIURL | ArcadeDB API URL |
| SecurityGroupId | Security group ID |
| SSHCommand | SSH connection command |

## Post-Deployment

After stack creation completes:

1. Access Studio: Use the `StudioURL` output value
2. Login with username `root` and your specified password
3. Create your first database
4. Configure additional users and permissions

## Updating Stacks

To update an existing stack:

```bash
aws cloudformation update-stack \
  --stack-name arcadedb-production \
  --template-body file://single-instance.yaml \
  --parameters ParameterKey=InstanceType,ParameterValue=m6i.xlarge
```

## Deleting Stacks

⚠️ **Warning:** This will delete all data. Ensure you have backups.

```bash
aws cloudformation delete-stack --stack-name arcadedb-production
```

## Troubleshooting

### Stack creation fails

1. Check CloudFormation Events tab for error details
2. Verify all parameters are correct
3. Ensure you have necessary permissions
4. Check VPC/subnet configuration

### Instance not accessible

1. Verify security group rules
2. Check AllowedCIDR parameter
3. Ensure subnet has internet gateway (for public access)

## HA cluster (ha-cluster.yaml)

> This template is validated statically (`cfn-lint`) in this repository, which has no AWS account. It was deployed on AWS on 2026-11-08 and again on 2026-11-11, after the fixed network interfaces (one ENI per node, Elastic IPs for `AssociatePublicIp`) were added (default VPC of `us-east-1`, `t3.large` nodes). Both runs passed the checks listed under "Verified on AWS" below. Items marked "unverified" are not covered by those runs.

### What gets created

| Resource | Count | Notes |
|----------|-------|-------|
| `AWS::EC2::NetworkInterface` | 3 | `Node0Eni`..`Node2Eni`: primary ENI of node N in `SubnetNId`, with the node security group; created before the instance, so the node's private IP is fixed |
| `AWS::EC2::EIP` + `AWS::EC2::EIPAssociation` | 0 or 3 | only with `AssociatePublicIp = true`, one per ENI |
| `AWS::EC2::Instance` | 3 | `Node0`..`Node2` run `node-0`..`node-2`, each on its own ENI; IMDSv2 required (launch template), encrypted gp3 root volume, no public IP by default |
| `AWS::EC2::LaunchTemplate` | 1 | only sets IMDSv2 (`HttpTokens: required`) |
| `AWS::EC2::SecurityGroup` + ingress rules | 1 | shared by the nodes (see [Network access](#network-access)) |
| `AWS::Route53::HostedZone` | 1 | private zone (default `arcadedb.internal`) attached to `VpcId` |
| `AWS::Route53::RecordSet` | 3 | `node-N.<zone>` A record → private IP of node N's ENI |
| internal NLB + target group + listener + NLB security group | 0 or 1 | only with `EnableNlb = true` (default) |

Every resource that supports tags is tagged `Cluster = <NamePrefix>` and `Application = ArcadeDB`, and gets its own `Name` tag (e.g. `arcadedb-ha-node-0`); the root volumes get the instance tags. No IAM role or instance profile is created, so no `--capabilities` flag is needed.

Creation order: the hosted zone and the network interfaces first, then the A records (they point at the ENI IPs), then the instances (`DependsOn` the three records). All three peer names therefore resolve when a node boots: there is no wait for DNS, and a node does not depend on the other instances being up. Nodes boot in parallel. The stack does not wait for ArcadeDB to start (the image has no `cfn-signal`): stack creation completes before the cluster is ready.

### How the cluster is configured

Each node's user data writes the same systemd override as `single-instance.yaml` (`ARCADEDB_SETTINGS`), plus the HA settings:

```
-Darcadedb.server.name=node-<N>
-Darcadedb.ha.enabled=true
-Darcadedb.ha.serverList=node-0.arcadedb.internal:2434:2480,node-1.arcadedb.internal:2434:2480,node-2.arcadedb.internal:2434:2480
-Darcadedb.ha.replicationFactor=3
-Darcadedb.server.readinessRequiresHA=true
```

The server name must be `node-<0-based index>`: ArcadeDB Raft uses the numeric suffix as an index into the server list. Raft uses port 2434, the HTTP API `ArcadeDBHttpPort` (2480). The root password is the same on every node.

Raft replication and elections never go through the NLB: every node connects to its peers directly on port 2434, using the `node-N.<PrivateZoneName>` names from the server list. The NLB only carries client HTTP traffic, so its health-check timing and connection handling cannot affect consensus.

The NLB health check is `GET /api/v1/ready` (unauthenticated, HTTP 200-399). With `readinessRequiresHA=true` a node only reports ready once it has joined the cluster, so only cluster members receive traffic. Followers forward writes to the leader, so any node can take a request (a write through the NLB succeeded in the test run).

### Prerequisites

- **Subscribe to the ArcadeDB listing on AWS Marketplace** before deploying (launching an unsubscribed Marketplace AMI fails), and pass the AMI ID for your region as `AmiId`, matching the architecture of `InstanceType` (see [Choose the AMI](#choose-the-ami)). CloudFormation cannot check the architecture: a mismatch fails when the instances launch.
- A VPC with **DNS support and DNS hostnames enabled** (`enableDnsSupport` and `enableDnsHostnames`). Without them the private hosted zone does not resolve and the nodes cannot find each other:

  ```bash
  aws ec2 modify-vpc-attribute --vpc-id vpc-xxxxx --enable-dns-support '{"Value":true}'
  aws ec2 modify-vpc-attribute --vpc-id vpc-xxxxx --enable-dns-hostnames '{"Value":true}'
  ```
- **Three subnets in that VPC, each in a different Availability Zone.** This template does not check it (the Terraform example does, at plan time; a CloudFormation `Rules` assertion with `Fn::ValueOf` might, but that is unverified). Two subnets in the same AZ deploy fine but lose the protection against an AZ outage; check before deploying:

  ```bash
  aws ec2 describe-subnets --subnet-ids subnet-aaaa subnet-bbbb subnet-cccc \
    --query 'Subnets[*].[SubnetId,AvailabilityZone,VpcId,CidrBlock]' --output table
  ```
- No other private hosted zone with the same name (`PrivateZoneName`) associated with the VPC, and no other load balancer or target group named `<NamePrefix>-nlb` / `<NamePrefix>-tg` in the region: use a distinct `NamePrefix` per stack.
- IAM permissions for EC2 (including network interfaces, and Elastic IPs when `AssociatePublicIp = true`), Elastic Load Balancing and Route 53.
- With `AssociatePublicIp = true`: an internet gateway on the VPC and three free Elastic IPs in the region quota (5 per region by default).

### Deploy

```bash
aws cloudformation deploy \
  --stack-name arcadedb-ha \
  --template-file ha-cluster.yaml \
  --parameter-overrides \
    AmiId=ami-xxxxx \
    VpcId=vpc-xxxxx \
    Subnet0Id=subnet-aaaa \
    Subnet1Id=subnet-bbbb \
    Subnet2Id=subnet-cccc \
    AllowedCidr=10.0.0.0/16 \
    ArcadeDBRootPassword='MySecurePass123!' \
    NamePrefix=arcadedb-ha
```

Read the outputs, then check the cluster from inside the VPC (or from a network routed into it, such as a VPN or peered VPC):

```bash
aws cloudformation describe-stacks --stack-name arcadedb-ha \
  --query 'Stacks[0].Outputs' --output table

STUDIO=$(aws cloudformation describe-stacks --stack-name arcadedb-ha \
  --query "Stacks[0].Outputs[?OutputKey=='StudioUrl'].OutputValue" --output text)
curl -s "$STUDIO/api/v1/ready" -o /dev/null -w '%{http_code}\n'
curl -s -u root:<password> "$STUDIO/api/v1/server?mode=cluster"
```

`StudioUrl` points at the NLB, or at `node-0.<zone>` when `EnableNlb = false`. Node DNS names only resolve inside the VPC.

### Network access

| Port | Source | Purpose |
|------|--------|---------|
| 2434 | the node security group itself | Raft between nodes |
| 2480 | the node security group itself | HTTP between nodes |
| 2480 | `AllowedCidr` | clients (API and Studio), directly or through the NLB |
| 2480 | the NLB security group (only with `EnableNlb`) | NLB health checks |
| 22 | `AllowedCidr` (only when `KeyName` is set) | SSH |

The NLB has its own security group, which allows the HTTP port from `AllowedCidr`. This differs from the Terraform example, which opens the HTTP port to the node subnets' CIDRs for the health checks: CloudFormation cannot read a subnet's CIDR from a parameter, so the nodes allow the NLB security group instead.

**`AllowedCidr` must cover the real clients.** The internal NLB keeps the client's source IP for instance targets, so the node security group sees the client address, not the NLB's. A client outside `AllowedCidr` is dropped even when it reaches the NLB.

Because client IPs are preserved, a node that calls the NLB can be routed back to itself and the connection times out. From a node, call the nodes by their own DNS names (`node-N.<PrivateZoneName>`) instead of the NLB.

`AllowedCidr` defaults to `10.0.0.0/16`, never `0.0.0.0/0`. Do not set it to `0.0.0.0/0`; especially not together with `AssociatePublicIp = true`, which would expose the API to the internet.

To reach the nodes without SSH, set `IamInstanceProfile` to an existing instance profile that grants `AmazonSSMManagedInstanceCore` and open a shell with SSM Session Manager (`aws ssm start-session --target <instance-id>`); the nodes need a route to the SSM endpoints (NAT gateway or VPC endpoints).

### Parameters

**Cluster & Network:**

| Parameter          | Required | Default           | Description |
|--------------------|----------|-------------------|-------------|
| VpcId              | Yes      | -                 | VPC ID (DNS support and hostnames enabled) |
| Subnet0Id          | Yes      | -                 | Subnet of node-0 |
| Subnet1Id          | Yes      | -                 | Subnet of node-1 (different AZ from the others) |
| Subnet2Id          | Yes      | -                 | Subnet of node-2 (different AZ from the others) |
| NamePrefix         | No       | arcadedb-ha       | Resource name prefix; also the `Cluster` tag (1-24 chars) |
| PrivateZoneName    | No       | arcadedb.internal | Route 53 private hosted zone for node discovery |
| EnableNlb          | No       | true              | Create the internal NLB on the HTTP port |
| AllowedCidr        | No       | 10.0.0.0/16       | CIDR allowed to reach the HTTP API (and SSH) |
| AssociatePublicIp  | No       | false             | Give each node an Elastic IP (needs an internet gateway) |
| KeyName            | No       | _(empty)_         | EC2 key pair; opens port 22 to `AllowedCidr` when set |
| IamInstanceProfile | No       | _(empty)_         | Name of an existing IAM instance profile to attach to the nodes (this template creates no IAM resources) |

**Instances & Storage:**

| Parameter        | Required | Default   | Description |
|------------------|----------|-----------|-------------|
| AmiId            | Yes      | -         | ArcadeDB AMI ID (amd64 or arm64, matching `InstanceType`) |
| InstanceType     | No       | m6i.large | EC2 instance type for all nodes (same allow-list as `single-instance.yaml`) |
| VolumeSize       | No       | 20        | Root volume size per node (GB) |
| VolumeType       | No       | gp3       | EBS volume type |
| EnableEncryption | No       | true      | Encrypt the root volumes |
| ArcadeDBVersion  | No       | 26.11.1   | Informational `Version` tag |

**ArcadeDB Configuration:**

| Parameter            | Required | Default    | Description |
|----------------------|----------|------------|-------------|
| ArcadeDBRootPassword | Yes      | -          | Root password, the same on every node (`NoEcho`) |
| ArcadeDBServerMode   | No       | production | Server mode (`development`, `test`, `production`) |
| ArcadeDBHttpPort     | No       | 2480       | HTTP port for API and Studio (also used in the server list and by the NLB; not 2434) |
| ArcadeDBPlugins      | No       | _(empty)_  | Comma-separated plugin list |
| ArcadeDBMaxRAM       | No       | 2048       | Max heap size in MB (`-Xmx`) |
| ArcadeDBJavaOpts     | No       | _(empty)_  | Additional `-Darcadedb.*` JVM flags (appended as-is on every node) |

The root password follows the same rule as `single-instance.yaml` (only `A-Z a-z 0-9 @ ! # ^ + = . _ & -`, at least one lowercase, uppercase, digit and special character) and has the same limitation: it ends up in the user data of all three instances (see [Password Security Limitation](#password-security-limitation)). Change it after the first login.

### Outputs

| Output          | Description |
|-----------------|-------------|
| NlbDnsName      | Internal NLB DNS name (only present when `EnableNlb = true`) |
| InstanceIds     | Instance IDs of node-0..node-2, comma-separated |
| PrivateIps      | Private IPs of node-0..node-2 (fixed, from the ENIs), comma-separated |
| NetworkInterfaceIds | Primary ENI IDs of node-0..node-2, comma-separated |
| PublicIps       | Elastic IPs of node-0..node-2, comma-separated (only present when `AssociatePublicIp = true`) |
| NodeDnsNames    | `node-N.<zone>` names of node-0..node-2, comma-separated |
| StudioUrl       | Studio URL: NLB, or node-0 when the NLB is disabled |
| ZoneName        | Private hosted zone name |
| ZoneId          | Private hosted zone ID |
| SecurityGroupId | Node security group ID |

### Cost

This runs three instances, three EBS volumes, an NLB and a hosted zone around the clock. As a rough order of magnitude with the defaults, at on-demand us-east-1 prices: 3 × `m6i.large` (about $0.096/hour each), plus the NLB (about $0.0225/hour plus capacity units), plus 3 × 20 GB gp3, plus $0.50/month for the hosted zone: in the region of $230/month before data transfer and any Marketplace software charge. Cross-AZ traffic (Raft replication, cross-zone load balancing) is billed as data transfer. Check the AWS Pricing Calculator for your region, and delete the stack when you are done.

### Verified on AWS

Two deployments (CloudFormation, default VPC of `us-east-1`, `t3.large` nodes, public IPs on so the test could reach the nodes through SSM) passed these checks, then were destroyed without leftovers: one on 2026-11-08, and one on 2026-11-11 with the fixed network interfaces and Elastic IPs:

- the three nodes formed one cluster with one leader;
- a record written through node-0 was readable on all three nodes;
- a write through the NLB succeeded and was readable afterwards;
- after stopping the leader, a surviving node became leader and writes still succeeded.

Not covered by those runs: replacing a node, changing user data on a running cluster, restoring from a backup, and sustained load. After the leader was stopped, the surviving nodes still reported three members, because a stopped node stays in the configured Raft peer set.

### Operations notes

- **Replacing a node:** if an instance fails, stop and start it (or rely on EC2 automatic recovery): it keeps its instance ID, ENI and root volume. The replacement attaches the same network interface, so it keeps the node's private IP and A record, and the other nodes need no DNS or configuration change. The new instance starts with an empty root volume (see the next point).
- **Data on replacement:** the databases and the Raft log live on the root volume, which is deleted with the instance. A replaced node rejoins with no data and has to catch up from the leader, so the time a replacement takes grows with the database size. Until it has caught up, only two nodes hold the data. Replace one node at a time and wait until the new one answers `/api/v1/ready` before touching the next. How ArcadeDB brings an empty node up to date (snapshot or log replay) and how long that takes is **unverified** for these templates. A separate EBS data volume that survives replacement is not part of this example.
- **Updates that replace an instance fail and roll back.** CloudFormation creates the new instance before it deletes the old one, and the ENI is still attached to the old one. That is safer than before: an update that replaces the instances (a new `AmiId`, for example) used to replace all three at the same time and lose every root volume. To move nodes to new instances, use the Terraform example (which replaces one node at a time), or deploy a new stack and move the data with a backup.
- **Changing user data** (password, ArcadeDB settings) on an existing stack: CloudFormation stops and starts the instance to apply new user data, but the script only runs on first boot. Change the systemd override on the hosts instead, or replace the nodes one at a time.
- The cluster keeps working with one node down (2 of 3 form a Raft majority); with two nodes down it stops accepting writes.

### Deleting the HA stack

```bash
aws cloudformation delete-stack --stack-name arcadedb-ha
aws cloudformation wait stack-delete-complete --stack-name arcadedb-ha
```

This deletes the instances, their root volumes, the network interfaces and the Elastic IPs, so **all data is lost**. Take a backup first if you need it. The hosted zone is deleted together with its three records; if you added records to the zone by hand, delete them first or the zone deletion fails.
