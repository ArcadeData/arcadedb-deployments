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
