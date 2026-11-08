# -----------------------------------------------------------------------------
# Instance Configuration
# -----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type. Must match the AMI architecture: x86_64 types for the amd64 AMI, t4g/m7g/r7g/c7g for the arm64 AMI."
  type        = string
  default     = "m6i.large"

  validation {
    condition     = contains(["t3.medium", "t3.large", "t3.xlarge", "m6i.large", "m6i.xlarge", "m6i.2xlarge", "m6i.4xlarge", "m7i.large", "m7i.xlarge", "m7i.2xlarge", "m7i.4xlarge", "r6i.large", "r6i.xlarge", "r6i.2xlarge", "r6i.4xlarge", "r7i.large", "r7i.xlarge", "r7i.2xlarge", "r7i.4xlarge", "c6i.large", "c6i.xlarge", "c6i.2xlarge", "c6i.4xlarge", "c7i.large", "c7i.xlarge", "c7i.2xlarge", "c7i.4xlarge", "t4g.medium", "t4g.large", "t4g.xlarge", "m7g.large", "m7g.xlarge", "m7g.2xlarge", "m7g.4xlarge", "r7g.large", "r7g.xlarge", "r7g.2xlarge", "r7g.4xlarge", "c7g.large", "c7g.xlarge", "c7g.2xlarge", "c7g.4xlarge"], var.instance_type)
    error_message = "Must be a supported instance type: t3, m6i, m7i, r6i, r7i, c6i, c7i (x86_64) or t4g, m7g, r7g, c7g (arm64) in the sizes listed in the README."
  }
}

variable "key_name" {
  description = "Name of an existing EC2 KeyPair for SSH access. If not set, the instance launches without SSH key access."
  type        = string
  default     = ""
}

variable "arcadedb_version" {
  description = "ArcadeDB version (informational tag)"
  type        = string
  default     = "26.11.1"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "vpc_id" {
  description = "VPC ID where ArcadeDB will be deployed. If not set, uses the default VPC."
  type        = string
  default     = ""
}

variable "subnet_id" {
  description = "Subnet ID for ArcadeDB instance (must be in selected VPC). If not set, uses the default subnet in zone a of the region (set it if that zone has no default subnet or does not offer the instance type)."
  type        = string
  default     = ""
}

variable "security_group_id" {
  description = "Pre-created security group ID. If not set, Terraform creates one (requires ec2:RevokeSecurityGroupEgress)."
  type        = string
  default     = ""
}

variable "allowed_cidr" {
  description = "CIDR block allowed to access ArcadeDB (e.g., 10.0.0.0/16 or your IP/32). Only used when security_group_id is not set."
  type        = string
  default     = "10.0.0.0/16"
}

# -----------------------------------------------------------------------------
# Storage Configuration
# -----------------------------------------------------------------------------

variable "volume_size" {
  description = "Size of the EBS volume in GB"
  type        = number
  default     = 20

  validation {
    condition     = var.volume_size >= 20 && var.volume_size <= 16384
    error_message = "Volume size must be between 20 and 16384 GB."
  }
}

variable "volume_type" {
  description = "EBS volume type"
  type        = string
  default     = "gp3"

  validation {
    condition     = contains(["gp3", "gp2", "io2"], var.volume_type)
    error_message = "Volume type must be gp3, gp2, or io2."
  }
}

variable "enable_encryption" {
  description = "Enable EBS volume encryption"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# ArcadeDB Configuration
# -----------------------------------------------------------------------------

variable "arcadedb_root_password" {
  description = "Root password for ArcadeDB: 8+ chars with lowercase, uppercase, a number and one of @!#^+=._&-. Other characters are rejected because the password is passed through the shell and systemd. It is stored in the instance user data, so change it after the first login."
  type        = string
  sensitive   = true

  validation {
    condition = (
      can(regex("^[A-Za-z0-9@!#^+=._&-]{8,}$", var.arcadedb_root_password)) &&
      can(regex("[a-z]", var.arcadedb_root_password)) &&
      can(regex("[A-Z]", var.arcadedb_root_password)) &&
      can(regex("[0-9]", var.arcadedb_root_password)) &&
      can(regex("[@!#^+=._&-]", var.arcadedb_root_password))
    )
    error_message = "Root password must be 8+ characters from A-Z a-z 0-9 @!#^+=._&- with at least one lowercase, uppercase, digit and special character."
  }
}

variable "arcadedb_server_mode" {
  description = "ArcadeDB server mode"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["development", "test", "production"], var.arcadedb_server_mode)
    error_message = "Server mode must be development, test, or production."
  }
}

variable "arcadedb_http_port" {
  description = "HTTP port for ArcadeDB API and Studio"
  type        = string
  default     = "2480"
}

variable "arcadedb_plugins" {
  description = "Comma-separated list of plugins, e.g. Postgres:com.arcadedb.postgres.PostgresProtocolPlugin"
  type        = string
  default     = ""
}

variable "arcadedb_max_ram" {
  description = "Max heap size in MB (sets JVM -Xmx)"
  type        = string
  default     = "2048"
}

variable "arcadedb_java_opts" {
  description = "Additional -Darcadedb.* JVM flags for advanced tuning (appended as-is to ARCADEDB_SETTINGS)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Optional Resources
# -----------------------------------------------------------------------------

variable "create_iam_resources" {
  description = "Create IAM role, instance profile, and CloudWatch alarm. Set to false for minimal-permission deployments."
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# AMI Configuration
# -----------------------------------------------------------------------------

variable "ami_id" {
  description = "ArcadeDB AMI ID. If not set, the latest matching AMI is looked up (see marketplace_product_code), for the architecture of instance_type."
  type        = string
  default     = ""
}

variable "marketplace_product_code" {
  description = "AWS Marketplace product code of the ArcadeDB listing (x86_64 or arm64, matching instance_type). If set, the AMI lookup uses Marketplace AMIs instead of AMIs owned by your account. Ignored when ami_id is set."
  type        = string
  default     = ""
}
