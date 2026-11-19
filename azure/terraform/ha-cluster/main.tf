data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

locals {
  node_count = 3
  raft_port  = 2434

  # Arm64 sizes carry a "p" among the feature letters (D2ps_v5, D4pds_v5, E2ps_v5, D2pls_v5, ...)
  is_arm          = can(regex("^Standard_[A-Z]+[0-9]+[a-z]*p[a-z]*_v[0-9]+$", var.vm_size))
  marketplace_sku = local.is_arm ? "arcadedb-ubuntu-arm64" : "arcadedb-ubuntu"
  use_marketplace = var.image_id == ""
  location        = coalesce(var.location, data.azurerm_resource_group.this.location)

  common_tags = merge(var.tags, {
    Cluster     = var.name_prefix
    Application = "ArcadeDB"
  })

  # /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>
  subnet_parts = split("/", var.subnet_id)
  vnet_id      = join("/", slice(local.subnet_parts, 0, 9))

  # Fixed private IPs, so the A records exist before any node boots.
  private_ips = length(var.private_ips) > 0 ? var.private_ips : [
    for i in range(local.node_count) : cidrhost(data.azurerm_subnet.this.address_prefixes[0], 10 + i)
  ]

  # ArcadeDB Raft requires server names with a 0-based numeric suffix: node-0, node-1, node-2.
  node_names     = [for i in range(local.node_count) : "node-${i}"]
  node_dns_names = [for name in local.node_names : "${name}.${var.private_zone_name}"]

  # Same list on every node: host:raftPort:httpPort, comma-separated.
  ha_server_list = join(",", [for dns in local.node_dns_names : "${dns}:${local.raft_port}:${var.arcadedb_http_port}"])

  # The image's own defaults (rootPasswordPath, database and backup directories) stay; the root
  # password is never an option here, so it does not show in `ps`. One entry per node: only the
  # server name differs.
  arcadedb_settings = [for name in local.node_names : join(" ", compact([
    "-Darcadedb.server.rootPasswordPath=/etc/arcadedb/root-password",
    "-Darcadedb.server.databaseDirectory=/var/lib/arcadedb/databases",
    "-Darcadedb.server.backupDirectory=/var/lib/arcadedb/backups",
    "-Darcadedb.server.mode=${var.arcadedb_server_mode}",
    "-Darcadedb.server.httpIncomingPort=${var.arcadedb_http_port}",
    "-Darcadedb.server.name=${name}",
    "-Darcadedb.ha.enabled=true",
    "-Darcadedb.ha.serverList=${local.ha_server_list}",
    "-Darcadedb.ha.replicationFactor=3",
    "-Darcadedb.server.readinessRequiresHA=true",
    var.arcadedb_plugins != "" ? "-Darcadedb.server.plugins=${var.arcadedb_plugins}" : "",
    var.arcadedb_java_opts,
  ]))]

  # /subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.Compute/galleries/<gallery>/images/<definition>/versions/<v>
  image_parts = split("/", var.image_id)

  custom_data = [for settings in local.arcadedb_settings : templatefile("${path.module}/cloud-init.yaml.tftpl", {
    arcadedb_root_password = var.arcadedb_root_password
    arcadedb_settings      = settings
    arcadedb_max_ram       = var.arcadedb_max_ram
  })]
}

# The subnet's address prefix, for the default node IPs.
data "azurerm_subnet" "this" {
  name                 = local.subnet_parts[10]
  virtual_network_name = local.subnet_parts[8]
  resource_group_name  = local.subnet_parts[4]
}

# Architecture of the gallery image definition, to catch a vm_size mismatch at plan time.
data "azurerm_shared_image" "this" {
  count = local.use_marketplace ? 0 : 1

  name                = local.image_parts[10]
  gallery_name        = local.image_parts[8]
  resource_group_name = local.image_parts[4]
}

# -----------------------------------------------------------------------------
# Network Security Group (nodes are grouped by an application security group)
# Azure's default rules already allow the load balancer probe.
# -----------------------------------------------------------------------------

resource "azurerm_application_security_group" "nodes" {
  name                = "${var.name_prefix}-nodes-asg"
  location            = local.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

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

resource "azurerm_network_security_rule" "raft" {
  name                                       = "arcadedb-raft-nodes"
  priority                                   = 110
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = tostring(local.raft_port)
  source_application_security_group_ids      = [azurerm_application_security_group.nodes.id]
  destination_application_security_group_ids = [azurerm_application_security_group.nodes.id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.this.name
}

resource "azurerm_network_security_rule" "node_http" {
  name                                       = "arcadedb-http-nodes"
  priority                                   = 120
  direction                                  = "Inbound"
  access                                     = "Allow"
  protocol                                   = "Tcp"
  source_port_range                          = "*"
  destination_port_range                     = var.arcadedb_http_port
  source_application_security_group_ids      = [azurerm_application_security_group.nodes.id]
  destination_application_security_group_ids = [azurerm_application_security_group.nodes.id]
  resource_group_name                        = var.resource_group_name
  network_security_group_name                = azurerm_network_security_group.this.name
}

resource "azurerm_network_security_rule" "ssh" {
  count = var.enable_ssh ? 1 : 0

  name                        = "ssh"
  priority                    = 130
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
# Network interfaces (one per node, static private IP)
# -----------------------------------------------------------------------------

resource "azurerm_network_interface" "node" {
  count = local.node_count

  name                = "${var.name_prefix}-${local.node_names[count.index]}-nic"
  location            = local.location
  resource_group_name = var.resource_group_name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.private_ips[count.index]
  }
}

resource "azurerm_network_interface_security_group_association" "node" {
  count = local.node_count

  network_interface_id      = azurerm_network_interface.node[count.index].id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_network_interface_application_security_group_association" "node" {
  count = local.node_count

  network_interface_id          = azurerm_network_interface.node[count.index].id
  application_security_group_id = azurerm_application_security_group.nodes.id
}

# -----------------------------------------------------------------------------
# Private DNS zone (node discovery)
# -----------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "this" {
  name                = var.private_zone_name
  resource_group_name = var.resource_group_name
  tags                = local.common_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "this" {
  name                  = "${var.name_prefix}-link"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.this.name
  virtual_network_id    = local.vnet_id
  registration_enabled  = false
  tags                  = local.common_tags
}

resource "azurerm_private_dns_a_record" "node" {
  count = local.node_count

  name                = local.node_names[count.index]
  zone_name           = azurerm_private_dns_zone.this.name
  resource_group_name = var.resource_group_name
  ttl                 = 60
  records             = [azurerm_network_interface.node[count.index].ip_configuration[0].private_ip_address]
  tags                = local.common_tags
}

# -----------------------------------------------------------------------------
# Virtual machines (node-0, node-1, node-2), one per availability zone
# -----------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "node" {
  count = local.node_count

  name                  = "${var.name_prefix}-${local.node_names[count.index]}"
  location              = local.location
  resource_group_name   = var.resource_group_name
  zone                  = var.availability_zones[count.index]
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.node[count.index].id]
  custom_data           = base64encode(local.custom_data[count.index])
  tags                  = local.common_tags

  # The image is Generation 2 and Trusted launch
  secure_boot_enabled = true
  vtpm_enabled        = true

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

  # Boot only once all three peer names resolve in the linked VNet, so ArcadeDB never sees
  # NXDOMAIN; and with the NSG and ASG already on the NIC, so the peers can reach each other.
  depends_on = [
    azurerm_private_dns_a_record.node,
    azurerm_private_dns_zone_virtual_network_link.this,
    azurerm_network_interface_security_group_association.node,
    azurerm_network_interface_application_security_group_association.node,
  ]

  lifecycle {
    precondition {
      condition     = local.use_marketplace || data.azurerm_shared_image.this[0].architecture == (local.is_arm ? "Arm64" : "x64")
      error_message = "The gallery image architecture does not match vm_size (Arm64 sizes need an Arm64 image, all others x64)."
    }
  }
}

# -----------------------------------------------------------------------------
# Internal Standard load balancer (optional), for client HTTP traffic only.
# Raft never goes through it: the nodes reach each other by name.
# -----------------------------------------------------------------------------

resource "azurerm_lb" "this" {
  count = var.enable_lb ? 1 : 0

  name                = "${var.name_prefix}-lb"
  location            = local.location
  resource_group_name = var.resource_group_name
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    zones                         = distinct(var.availability_zones)
  }
}

resource "azurerm_lb_backend_address_pool" "nodes" {
  count = var.enable_lb ? 1 : 0

  name            = "nodes"
  loadbalancer_id = azurerm_lb.this[0].id
}

# /api/v1/ready is unauthenticated. With readinessRequiresHA=true a node only reports ready
# once it is part of the cluster.
resource "azurerm_lb_probe" "http" {
  count = var.enable_lb ? 1 : 0

  name                = "arcadedb-ready"
  loadbalancer_id     = azurerm_lb.this[0].id
  protocol            = "Http"
  port                = tonumber(var.arcadedb_http_port)
  request_path        = "/api/v1/ready"
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "http" {
  count = var.enable_lb ? 1 : 0

  name                           = "arcadedb-http"
  loadbalancer_id                = azurerm_lb.this[0].id
  protocol                       = "Tcp"
  frontend_port                  = tonumber(var.arcadedb_http_port)
  backend_port                   = tonumber(var.arcadedb_http_port)
  frontend_ip_configuration_name = "internal"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.nodes[0].id]
  probe_id                       = azurerm_lb_probe.http[0].id
}

resource "azurerm_network_interface_backend_address_pool_association" "node" {
  count = var.enable_lb ? local.node_count : 0

  network_interface_id    = azurerm_network_interface.node[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.nodes[0].id
}
