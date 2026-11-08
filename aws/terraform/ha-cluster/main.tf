terraform {
  required_version = ">= 1.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# Every resource that supports tags gets Cluster = <name_prefix>, so the
# cluster's resources can be found (and cleaned up) by tag. Each resource also
# sets its own Name tag.
provider "aws" {
  default_tags {
    tags = {
      Cluster     = var.name_prefix
      Application = "ArcadeDB"
    }
  }
}

locals {
  node_count = 3
  raft_port  = 2434
  http_port  = tonumber(var.arcadedb_http_port)

  # ArcadeDB Raft requires server names with a 0-based numeric suffix: node-0, node-1, node-2.
  node_names     = [for i in range(local.node_count) : "node-${i}"]
  node_dns_names = [for name in local.node_names : "${name}.${var.private_zone_name}"]

  # Same list on every node: host:raftPort:httpPort, comma-separated.
  ha_server_list = join(",", [for dns in local.node_dns_names : "${dns}:${local.raft_port}:${local.http_port}"])

  # Graviton instance families (t4g, m7g, r7g, c7g, ...) run the arm64 AMI
  is_arm            = can(regex("^[a-z]+[0-9]+g[a-z]*\\.", var.instance_type))
  ami_architecture  = local.is_arm ? "arm64" : "x86_64"
  ami_id_from_input = length(regexall(":", var.ami_id)) > 0 ? split(":", var.ami_id)[1] : var.ami_id
  # Strip an optional "region:" prefix from the AMI ID (e.g. "us-east-1:ami-0abc")
  ami_id = var.ami_id != "" ? local.ami_id_from_input : data.aws_ami.arcadedb[0].id
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
    values = [local.ami_architecture]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# When ami_id is given, look it up too, so an architecture mismatch with
# instance_type fails at plan time instead of at launch.
data "aws_ami" "selected" {
  count = var.ami_id != "" ? 1 : 0

  filter {
    name   = "image-id"
    values = [local.ami_id_from_input]
  }
}

# -----------------------------------------------------------------------------
# Subnets (one per node, each in a different Availability Zone)
# -----------------------------------------------------------------------------

data "aws_subnet" "node" {
  count = local.node_count
  id    = var.subnet_ids[count.index]
}

# -----------------------------------------------------------------------------
# Security Group
# Creating a SG via Terraform requires ec2:RevokeSecurityGroupEgress because
# the AWS provider revokes the default egress rule on creation.
# -----------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name_prefix = "${var.name_prefix}-"
  description = "ArcadeDB HA cluster nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "ArcadeDB Raft between cluster nodes"
    from_port   = local.raft_port
    to_port     = local.raft_port
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "ArcadeDB HTTP API between cluster nodes"
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description = "ArcadeDB HTTP API and Studio from clients"
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  # NLB health checks come from the load balancer's private IPs, which live in
  # the node subnets. Client traffic through the NLB keeps the client IP and is
  # covered by allowed_cidr above.
  dynamic "ingress" {
    for_each = var.enable_nlb ? [1] : []
    content {
      description = "NLB health checks from the node subnets"
      from_port   = local.http_port
      to_port     = local.http_port
      protocol    = "tcp"
      cidr_blocks = data.aws_subnet.node[*].cidr_block
    }
  }

  dynamic "ingress" {
    for_each = var.key_name != "" ? [1] : []
    content {
      description = "SSH access"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [var.allowed_cidr]
    }
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg"
  }

  lifecycle {
    precondition {
      condition     = length(distinct(data.aws_subnet.node[*].availability_zone)) == local.node_count
      error_message = "subnet_ids must be in three different Availability Zones; got ${join(", ", data.aws_subnet.node[*].availability_zone)}."
    }

    precondition {
      condition     = alltrue([for s in data.aws_subnet.node : s.vpc_id == var.vpc_id])
      error_message = "All subnet_ids must belong to vpc_id (${var.vpc_id})."
    }
  }
}

# -----------------------------------------------------------------------------
# Route 53 private hosted zone (node discovery)
# Requires enableDnsSupport and enableDnsHostnames on the VPC.
# -----------------------------------------------------------------------------

resource "aws_route53_zone" "private" {
  name    = var.private_zone_name
  comment = "ArcadeDB HA cluster ${var.name_prefix} node discovery"

  vpc {
    vpc_id = var.vpc_id
  }

  tags = {
    Name = "${var.name_prefix}-zone"
  }
}

resource "aws_route53_record" "node" {
  count   = local.node_count
  zone_id = aws_route53_zone.private.zone_id
  name    = local.node_dns_names[count.index]
  type    = "A"
  ttl     = 60
  records = [aws_instance.node[count.index].private_ip]
}

# -----------------------------------------------------------------------------
# EC2 Instances (node-0, node-1, node-2)
# -----------------------------------------------------------------------------

resource "aws_instance" "node" {
  count = local.node_count

  ami                         = local.ami_id
  instance_type               = var.instance_type
  key_name                    = var.key_name != "" ? var.key_name : null
  iam_instance_profile        = var.iam_instance_profile != "" ? var.iam_instance_profile : null
  subnet_id                   = var.subnet_ids[count.index]
  vpc_security_group_ids      = [aws_security_group.node.id]
  associate_public_ip_address = var.associate_public_ip

  # Require IMDSv2 (session tokens)
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = var.volume_size
    volume_type = var.volume_type
    encrypted   = var.enable_encryption

    tags = {
      Name        = "${var.name_prefix}-${local.node_names[count.index]}-root"
      Cluster     = var.name_prefix
      Application = "ArcadeDB"
    }
  }

  # Userdata differs per node only by the server name; the server list is the
  # same DNS-name list everywhere.
  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    node_name              = local.node_names[count.index]
    ha_server_list         = local.ha_server_list
    peer_dns_names         = join(" ", local.node_dns_names)
    arcadedb_root_password = var.arcadedb_root_password
    arcadedb_server_mode   = var.arcadedb_server_mode
    arcadedb_http_port     = var.arcadedb_http_port
    arcadedb_plugins       = var.arcadedb_plugins
    arcadedb_max_ram       = var.arcadedb_max_ram
    arcadedb_java_opts     = var.arcadedb_java_opts
  })

  tags = {
    Name    = "${var.name_prefix}-${local.node_names[count.index]}"
    Node    = local.node_names[count.index]
    Version = var.arcadedb_version
  }

  lifecycle {
    precondition {
      condition     = var.ami_id == "" || try(data.aws_ami.selected[0].architecture, "") == local.ami_architecture
      error_message = "ami_id ${var.ami_id} does not match instance_type ${var.instance_type}: expected a ${local.ami_architecture} AMI."
    }
  }
}

# -----------------------------------------------------------------------------
# Internal Network Load Balancer (optional)
# -----------------------------------------------------------------------------

resource "aws_lb" "nlb" {
  count = var.enable_nlb ? 1 : 0

  name                             = "${var.name_prefix}-nlb"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = var.subnet_ids
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "${var.name_prefix}-nlb"
  }
}

resource "aws_lb_target_group" "http" {
  count = var.enable_nlb ? 1 : 0

  name                 = "${var.name_prefix}-tg"
  port                 = local.http_port
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  # /api/v1/ready is unauthenticated. With readinessRequiresHA=true a node only
  # reports ready once it is part of the cluster.
  health_check {
    protocol            = "HTTP"
    path                = "/api/v1/ready"
    port                = "traffic-port"
    matcher             = "200-399"
    interval            = 10
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.name_prefix}-tg"
  }
}

resource "aws_lb_listener" "http" {
  count = var.enable_nlb ? 1 : 0

  load_balancer_arn = aws_lb.nlb[0].arn
  port              = local.http_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http[0].arn
  }

  tags = {
    Name = "${var.name_prefix}-listener"
  }
}

resource "aws_lb_target_group_attachment" "node" {
  count = var.enable_nlb ? local.node_count : 0

  target_group_arn = aws_lb_target_group.http[0].arn
  target_id        = aws_instance.node[count.index].id
  port             = local.http_port
}
