data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  # Arm64 sizes carry a "p" among the feature letters (D2ps_v5, D4pds_v5, E2ps_v5, D2pls_v5, ...)
  is_arm          = can(regex("^Standard_[A-Z]+[0-9]+[a-z]*p[a-z]*_v[0-9]+$", var.vm_size))
  marketplace_sku = local.is_arm ? "arcadedb-ubuntu-arm64" : "arcadedb-ubuntu"
  # Azure rejects Trusted launch on the Ampere Arm64 sizes (Dpsv5, Epsv5), so Arm64 defaults to off
  trusted_launch  = var.trusted_launch != null ? var.trusted_launch : !local.is_arm
  use_marketplace = var.image_id == ""
  location        = coalesce(var.location, data.azurerm_resource_group.this.location)

  common_tags = merge(var.tags, {
    Cluster     = var.name_prefix
    Application = "ArcadeDB"
  })

  # The image's own defaults (rootPasswordPath, database and backup directories) stay; the root
  # password is never an option here, so it does not show in `ps`.
  arcadedb_settings = join(" ", compact([
    "-Darcadedb.server.rootPasswordPath=/etc/arcadedb/root-password",
    "-Darcadedb.server.databaseDirectory=/var/lib/arcadedb/databases",
    "-Darcadedb.server.backupDirectory=/var/lib/arcadedb/backups",
    "-Darcadedb.server.mode=${var.arcadedb_server_mode}",
    "-Darcadedb.server.httpIncomingPort=${var.arcadedb_http_port}",
    var.arcadedb_plugins != "" ? "-Darcadedb.server.plugins=${var.arcadedb_plugins}" : "",
    var.arcadedb_java_opts,
  ]))

  # /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/<v>
  image_parts = split("/", var.image_id)

  custom_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    arcadedb_root_password = var.arcadedb_root_password
    arcadedb_settings      = local.arcadedb_settings
    arcadedb_max_ram       = var.arcadedb_max_ram
  })
}

# Architecture of the gallery image definition, to catch a vm_size mismatch at plan time.
data "azurerm_shared_image" "this" {
  count = local.use_marketplace ? 0 : 1

  name                = local.image_parts[10]
  gallery_name        = local.image_parts[8]
  resource_group_name = local.image_parts[4]
}

# -----------------------------------------------------------------------------
# Network Security Group
# -----------------------------------------------------------------------------

resource "azurerm_network_security_group" "this" {
  name                = "${var.name_prefix}-nsg"
  location            = local.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_network_security_rule" "http" {
  name                        = "arcadedb-http"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = var.arcadedb_http_port
  source_address_prefix       = var.allowed_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

resource "azurerm_network_security_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  name                        = "ssh"
  priority                    = 110
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.allowed_cidr
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}

# -----------------------------------------------------------------------------
# Network Interface (and optional public IP)
# -----------------------------------------------------------------------------

resource "azurerm_public_ip" "this" {
  count = var.public_ip ? 1 : 0

  name                = "${var.name_prefix}-pip"
  location            = local.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

resource "azurerm_network_interface" "this" {
  name                = "${var.name_prefix}-nic"
  location            = local.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = var.public_ip ? azurerm_public_ip.this[0].id : null
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# -----------------------------------------------------------------------------
# Virtual Machine
# -----------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "this" {
  name                  = "${var.name_prefix}-vm"
  location              = local.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.this.id]
  custom_data           = base64encode(local.custom_data)
  tags                  = local.common_tags

  # The image is Generation 2 and supports Trusted launch; Standard security when it is off
  secure_boot_enabled = local.trusted_launch
  vtpm_enabled        = local.trusted_launch

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.admin_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  # Marketplace image, or a Compute Gallery image version when image_id is set
  source_image_id = local.use_marketplace ? null : var.image_id

  dynamic "source_image_reference" {
    for_each = local.use_marketplace ? [1] : []
    content {
      publisher = "arcadedb"
      offer     = "arcadedb"
      sku       = local.marketplace_sku
      version   = var.image_version
    }
  }

  dynamic "plan" {
    for_each = local.use_marketplace ? [1] : []
    content {
      publisher = "arcadedb"
      product   = "arcadedb"
      name      = local.marketplace_sku
    }
  }

  # Managed storage account
  boot_diagnostics {}

  lifecycle {
    precondition {
      condition     = local.use_marketplace || data.azurerm_shared_image.this[0].architecture == (local.is_arm ? "Arm64" : "x64")
      error_message = "The gallery image architecture does not match vm_size (Arm64 sizes need an Arm64 image, all others x64)."
    }
  }
}
