# ArcadeDB on AWS

Two ways to run ArcadeDB on EC2 from the ArcadeDB AWS Marketplace AMI, each available as Terraform and as CloudFormation: a single instance, or a 3-node high-availability cluster (Raft consensus).

## Choosing a topology

| | Single instance | 3-node HA cluster |
|---|---|---|
| Nodes | 1 EC2 instance | 3 EC2 instances, one per Availability Zone |
| Availability | No failover | Survives the loss of one node |
| Discovery | n/a | Route 53 private hosted zone (`node-0..2.arcadedb.internal`) |
| Entry point | Instance IP, port 2480 | Optional internal Network Load Balancer (on by default) |
| Good for | Development, testing, small workloads | Production-style resilience |

## Prerequisites

- An AWS account and credentials configured for the AWS CLI
- An active subscription to the ArcadeDB listing on AWS Marketplace (required to launch its AMI)
- An existing VPC and subnet(s); the HA cluster needs three subnets in three different Availability Zones, in a VPC with DNS support and DNS hostnames enabled
- Optionally, an EC2 key pair (only for SSH access)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.2 for `ha-cluster` (>= 1.0 for `single-instance`), or the [AWS CLI](https://aws.amazon.com/cli/) for the CloudFormation templates

## Layout

```
aws/
├── terraform/
│   ├── single-instance/   # one EC2 instance
│   └── ha-cluster/        # 3 nodes, Route 53 private zone, optional NLB
└── cloudformation/
    ├── single-instance.yaml
    ├── ha-cluster.yaml
    └── README.md
```

## Documentation

- [Terraform: single instance](./terraform/single-instance/README.md)
- [Terraform: HA cluster](./terraform/ha-cluster/README.md)
- [CloudFormation: both templates](./cloudformation/README.md)

## Validation

The templates are validated statically in this repository's CI (`terraform fmt` and `validate`, `cfn-lint`). Unlike the other scenarios there is no `start.sh` or `test.sh`, because this repository has no AWS account. The templates are deployed for real by the maintainers' own pipeline. On 2026-11-08 both HA examples were deployed once on AWS by that pipeline (3 nodes formed a cluster, a write replicated to every node, a write through the NLB succeeded, and a write succeeded after the leader was stopped), then destroyed. Anything the sub-READMEs still mark as "unverified" has not been exercised yet.

## Cost warning

These examples create billable AWS resources: EC2 instances, EBS volumes, and for the HA cluster a Route 53 hosted zone and (by default) a Network Load Balancer. Three nodes cost roughly three times a single instance. Destroy the resources when you are done (`terraform destroy` or `aws cloudformation delete-stack`).

## Security

Restrict `allowed_cidr` / `AllowedCidr` to the addresses that need access, and change the root password after the first login. See the sub-READMEs for details.
