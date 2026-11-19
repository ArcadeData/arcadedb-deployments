# -----------------------------------------------------------------------------
# Placement
# -----------------------------------------------------------------------------

variable "resource_group_name" {
  description = "Name of an existing resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region. If not set, the location of the resource group is used."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix for the names of all resources, also set as the Cluster tag."
  type        = string
  default     = "arcadedb"
}

# -----------------------------------------------------------------------------
# VM Configuration
# -----------------------------------------------------------------------------

variable "vm_size" {
  description = "VM size. Arm64 sizes (Standard_D2ps_v5, Standard_D4pds_v5, Standard_E2ps_v5, ...) get the Arm64 image, everything else the x64 image. Must be a Generation 2, Trusted launch capable size."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "admin_username" {
  description = "Administrator user created on the VM (SSH key login only)."
  type        = string
  default     = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "SSH public key for admin_username (e.g. the contents of ~/.ssh/id_ed25519.pub)."
  type        = string
}

variable "os_disk_size_gb" {
  description = "Size of the OS disk in GB"
  type        = number
  default     = 30

  validation {
    condition     = var.os_disk_size_gb >= 30 && var.os_disk_size_gb <= 4095
    error_message = "OS disk size must be between 30 and 4095 GB."
  }
}

variable "os_disk_type" {
  description = "OS disk storage type"
  type        = string
  default     = "Premium_LRS"

  validation {
    condition     = contains(["Premium_LRS", "StandardSSD_LRS", "Standard_LRS", "Premium_ZRS", "StandardSSD_ZRS"], var.os_disk_type)
    error_message = "OS disk type must be Premium_LRS, StandardSSD_LRS, Standard_LRS, Premium_ZRS or StandardSSD_ZRS."
  }
}

# -----------------------------------------------------------------------------
# Image Configuration
# -----------------------------------------------------------------------------

variable "image_id" {
  description = "Resource ID of a Compute Gallery image version to deploy instead of the Marketplace image (no plan, no terms to accept). Its architecture must match vm_size."
  type        = string
  default     = ""
}

variable "image_version" {
  description = "Version of the Marketplace image (e.g. 26.11.1). Ignored when image_id is set."
  type        = string
  default     = "latest"
}

# -----------------------------------------------------------------------------
# Network Configuration
# -----------------------------------------------------------------------------

variable "subnet_id" {
  description = "ID of an existing subnet for the VM."
  type        = string
}

variable "allowed_cidr" {
  description = "CIDR block allowed to reach ArcadeDB (e.g. 10.0.0.0/16 or your IP/32)."
  type        = string
}

variable "enable_ssh" {
  description = "Allow SSH (port 22) from allowed_cidr."
  type        = bool
  default     = false
}

variable "public_ip" {
  description = "Attach a Standard static public IP to the VM."
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# ArcadeDB Configuration
# -----------------------------------------------------------------------------

variable "arcadedb_root_password" {
  description = "Root password for ArcadeDB: at least 8 characters from A-Z a-z 0-9 @!#^+=._&-. If empty, the image generates a unique password on first boot (see the root_password_hint output). It is stored in the VM's custom data, so change it after the first login."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.arcadedb_root_password == "" || (length(var.arcadedb_root_password) >= 8 && can(regex("^[A-Za-z0-9@!#^+=._&-]+$", var.arcadedb_root_password)))
    error_message = "Root password must be empty (generated on first boot) or at least 8 characters from A-Z a-z 0-9 @ ! # ^ + = . _ & - (ArcadeDB rejects shorter root passwords)."
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
  description = "Max heap size in MB (sets JVM -Xmx), a whole number without unit, e.g. 2048"
  type        = string
  default     = "2048"

  validation {
    condition     = can(regex("^[1-9][0-9]*$", var.arcadedb_max_ram))
    error_message = "arcadedb_max_ram must be a positive whole number of megabytes without a unit, e.g. 2048 (it becomes -Xmx<value>m)."
  }
}

variable "arcadedb_java_opts" {
  description = "Additional -Darcadedb.* JVM flags for advanced tuning (appended as-is to ARCADEDB_SETTINGS; avoid double quotes)"
  type        = string
  default     = ""
}

# -----------------------------------------------------------------------------
# Tags
# -----------------------------------------------------------------------------

variable "tags" {
  description = "Tags added to every resource, together with Cluster and Application."
  type        = map(string)
  default     = {}
}
