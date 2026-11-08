terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# -----------------------------------------------------------------------------
# AMI Lookup (fallback when ami_id is not provided)
# -----------------------------------------------------------------------------

data "aws_ami" "arcadedb" {
  count = var.ami_id == "" ? 1 : 0

  most_recent = true
  owners      = var.marketplace_product_code != "" ? ["aws-marketplace"] : ["self"]

  dynamic "filter" {
    for_each = var.marketplace_product_code != "" ? [] : [1]
    content {
      name   = "name"
      values = ["*arcadedb*"]
    }
  }

  dynamic "filter" {
    for_each = var.marketplace_product_code != "" ? [1] : []
    content {
      name   = "product-code"
      values = [var.marketplace_product_code]
    }
  }

  # Pick the AMI that matches the instance type, so a Graviton type never gets the x86_64 image.
  filter {
    name   = "architecture"
    values = [local.is_arm ? "arm64" : "x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  # Graviton instance families (t4g, m7g, r7g, c7g, ...) run the arm64 AMI
  is_arm = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
  # Strip an optional "region:" prefix from the AMI ID (e.g. "us-east-1:ami-0abc")
  ami_id_raw        = var.ami_id != "" ? var.ami_id : data.aws_ami.arcadedb[0].id
  ami_id            = length(regexall(":", local.ami_id_raw)) > 0 ? split(":", local.ami_id_raw)[1] : local.ami_id_raw
  vpc_id            = var.vpc_id != "" ? var.vpc_id : data.aws_vpcs.default[0].ids[0]
  subnet_id         = var.subnet_id != "" ? var.subnet_id : sort(data.aws_subnets.default[0].ids)[0]
  create_sg         = var.security_group_id == ""
  security_group_id = local.create_sg ? aws_security_group.arcadedb[0].id : var.security_group_id
}

# -----------------------------------------------------------------------------
# Default VPC / Subnet Lookup (fallback when vpc_id or subnet_id is not provided)
# Uses aws_vpcs (DescribeVpcs) instead of aws_vpc (DescribeVpcAttribute)
# to avoid requiring the ec2:DescribeVpcAttribute permission.
# -----------------------------------------------------------------------------

data "aws_vpcs" "default" {
  count = var.vpc_id == "" ? 1 : 0

  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

data "aws_subnets" "default" {
  count = var.subnet_id == "" ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }

  # Zone "a" is used because not every zone offers every family (e.g. us-east-1e has no m6i or t4g).
  # Set subnet_id to deploy elsewhere; looking zones up would need ec2:DescribeInstanceTypeOfferings.
  filter {
    name   = "availability-zone"
    values = ["${data.aws_region.current.id}a"]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# -----------------------------------------------------------------------------
# Security Group (optional — skipped when security_group_id is provided)
# Creating a SG via Terraform requires ec2:RevokeSecurityGroupEgress because
# the AWS provider revokes the default egress rule on creation. Pass a
# pre-created security_group_id to avoid this.
# -----------------------------------------------------------------------------

resource "aws_security_group" "arcadedb" {
  count       = local.create_sg ? 1 : 0
  name_prefix = "arcadedb-"
  description = "Security group for ArcadeDB instance"
  vpc_id      = local.vpc_id

  ingress {
    description = "ArcadeDB HTTP API"
    from_port   = var.arcadedb_http_port
    to_port     = var.arcadedb_http_port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "ArcadeDB HTTPS API"
    from_port   = 2484
    to_port     = 2484
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "arcadedb-sg"
  }
}

# -----------------------------------------------------------------------------
# IAM Role & Instance Profile (optional — for CloudWatch and SSM integration)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "arcadedb" {
  count       = var.create_iam_resources ? 1 : 0
  name_prefix = "arcadedb-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  managed_policy_arns = [
    "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  tags = {
    Name = "arcadedb-role"
  }
}

resource "aws_iam_instance_profile" "arcadedb" {
  count       = var.create_iam_resources ? 1 : 0
  name_prefix = "arcadedb-"
  role        = aws_iam_role.arcadedb[0].name
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------

resource "aws_instance" "arcadedb" {
  ami                    = local.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = var.create_iam_resources ? aws_iam_instance_profile.arcadedb[0].name : null
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [local.security_group_id]

  # Require IMDSv2 (session tokens)
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = var.volume_type
    encrypted   = var.enable_encryption
  }

  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    arcadedb_root_password = var.arcadedb_root_password
    arcadedb_server_mode   = var.arcadedb_server_mode
    arcadedb_http_port     = var.arcadedb_http_port
    arcadedb_plugins       = var.arcadedb_plugins
    arcadedb_max_ram       = var.arcadedb_max_ram
    arcadedb_java_opts     = var.arcadedb_java_opts
  })

  tags = {
    Name        = "arcadedb-instance"
    Application = "ArcadeDB"
    Version     = var.arcadedb_version
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Recovery Alarm
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "arcadedb_recovery" {
  count               = var.create_iam_resources ? 1 : 0
  alarm_name          = "arcadedb-recovery-${aws_instance.arcadedb.id}"
  alarm_description   = "Trigger recovery when instance status check fails"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"

  dimensions = {
    InstanceId = aws_instance.arcadedb.id
  }

  alarm_actions = [
    "arn:aws:automate:${data.aws_region.current.id}:ec2:recover"
  ]
}

data "aws_region" "current" {}
