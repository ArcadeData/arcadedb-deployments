mock_provider "azurerm" {
  override_data {
    target = data.azurerm_resource_group.this
    values = {
      location = "eastus"
    }
  }

  override_data {
    target = data.azurerm_subnet.this
    values = {
      address_prefixes = ["10.42.0.0/24"]
    }
  }

  override_data {
    target = data.azurerm_shared_image.this
    values = {
      architecture = "x64"
    }
  }

  # A known ASG ID at plan time, so the Raft rule's source and destination can be compared with it.
  override_resource {
    target          = azurerm_application_security_group.nodes
    override_during = plan
    values = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/applicationSecurityGroups/arcadedb-ha-nodes-asg"
    }
  }
}

variables {
  resource_group_name    = "rg-test"
  subnet_id              = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-test"
  admin_ssh_public_key   = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCvJ9TOr4PX2ScseRc57qAtVrIvruGzWAZ5MHTh/S4jX4J0VeYfoh8qAzPXCASOt2bTOrI1XmhSXON+nuWNt93nBop4FAA65e3I76iMti1gu8fBuzkRQ2XQxhmJM+lquw8V6hb4op+LAWhq7ZNh8DvIZQwuuVd+QA5/qgjO6EHuLD4dsJSKsV72XKgUIaIjb0CEevwkqG61zmZnp2l419gKuAf5y2AqKqfIdHjHgLAQXf73rMv6+n1tg7ZcxrUmHFcgY3S9lW0JDJ///zYwF4HmDm7CP8JWW2mbX5/SMAlJj6XcRVz+JgYn++ddbaY21szI2vPEAqt/IWiWMUZHh0X/ test"
  allowed_cidr           = "10.0.0.0/16"
  arcadedb_root_password = "Test.Pass-1"
}

run "defaults" {
  command = plan

  assert {
    condition     = length(azurerm_linux_virtual_machine.node) == 3 && [for vm in azurerm_linux_virtual_machine.node : vm.name] == ["arcadedb-ha-node-0", "arcadedb-ha-node-1", "arcadedb-ha-node-2"]
    error_message = "Three VMs named <prefix>-node-0..2"
  }
  assert {
    condition     = [for vm in azurerm_linux_virtual_machine.node : vm.zone] == ["1", "2", "3"]
    error_message = "One VM per availability zone 1, 2, 3"
  }
  assert {
    condition     = [for n in azurerm_network_interface.node : n.ip_configuration[0].private_ip_address] == ["10.42.0.10", "10.42.0.11", "10.42.0.12"]
    error_message = "NIC IPs must default to cidrhost(subnet, 10 + N)"
  }
  assert {
    condition     = alltrue([for n in azurerm_network_interface.node : n.ip_configuration[0].private_ip_address_allocation == "Static"])
    error_message = "NIC IPs must be static"
  }
  assert {
    condition     = [for r in azurerm_private_dns_a_record.node : r.name] == ["node-0", "node-1", "node-2"]
    error_message = "A records must be node-0..2"
  }
  assert {
    condition     = [for r in azurerm_private_dns_a_record.node : one(r.records)] == ["10.42.0.10", "10.42.0.11", "10.42.0.12"]
    error_message = "A records must point at the node IPs"
  }
  assert {
    condition     = length(azurerm_private_dns_a_record.node) == length(azurerm_linux_virtual_machine.node)
    error_message = "One A record per VM (the VMs depend on them)"
  }
  assert {
    condition     = azurerm_private_dns_zone.this.name == "arcadedb.internal"
    error_message = "Private zone must default to arcadedb.internal"
  }
  assert {
    condition     = azurerm_private_dns_zone_virtual_network_link.this.virtual_network_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-test" && !azurerm_private_dns_zone_virtual_network_link.this.registration_enabled
    error_message = "Zone must be linked to the subnet's VNet, registration off"
  }
  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.node : vm.secure_boot_enabled && vm.vtpm_enabled && vm.disable_password_authentication])
    error_message = "Trusted launch on, password login off"
  }
  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.node : vm.plan[0].name == "arcadedb-ubuntu" && vm.source_image_reference[0].version == "latest"])
    error_message = "Marketplace x64 image by default"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.node[0].size == "Standard_D2s_v5"
    error_message = "Default size is Standard_D2s_v5"
  }
}

run "server_list" {
  command = plan

  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "-Darcadedb.server.name=node-1")
    error_message = "node-1 must be named node-1"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "-Darcadedb.ha.serverList=node-0.arcadedb.internal:2434:2480,node-1.arcadedb.internal:2434:2480,node-2.arcadedb.internal:2434:2480")
    error_message = "Server list must be node-N.<zone>:2434:<http_port>"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "-Darcadedb.ha.enabled=true")
    error_message = "HA must be enabled"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "-Darcadedb.ha.replicationFactor=3")
    error_message = "Replication factor must be 3"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "-Darcadedb.server.readinessRequiresHA=true")
    error_message = "Readiness must require HA"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "rootPasswordPath=/etc/arcadedb/root-password") && strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "path: /etc/arcadedb/root-password")
    error_message = "Password goes to the root-password file"
  }
  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.node[1].custom_data), "rootPassword=")
    error_message = "The password must never be a -D option"
  }
}

run "private_ips_override" {
  command = plan
  variables {
    private_ips = ["10.42.0.240", "10.42.0.241", "10.42.0.242"]
  }
  assert {
    condition     = [for n in azurerm_network_interface.node : n.ip_configuration[0].private_ip_address] == ["10.42.0.240", "10.42.0.241", "10.42.0.242"]
    error_message = "NIC IPs must follow private_ips"
  }
  assert {
    condition     = [for r in azurerm_private_dns_a_record.node : one(r.records)] == ["10.42.0.240", "10.42.0.241", "10.42.0.242"]
    error_message = "A records must follow private_ips"
  }
}

run "private_ips_wrong_length" {
  command = plan
  variables {
    private_ips = ["10.42.0.240"]
  }
  expect_failures = [var.private_ips]
}

run "lb" {
  command = plan
  assert {
    condition     = length(azurerm_lb.this) == 1 && azurerm_lb.this[0].sku == "Standard" && azurerm_lb.this[0].frontend_ip_configuration[0].subnet_id == var.subnet_id
    error_message = "One internal Standard LB in the subnet"
  }
  assert {
    condition     = toset(azurerm_lb.this[0].frontend_ip_configuration[0].zones) == toset(["1", "2", "3"])
    error_message = "LB frontend must be zone-redundant"
  }
  assert {
    condition     = azurerm_lb_probe.http[0].protocol == "Tcp" && azurerm_lb_probe.http[0].request_path == null && azurerm_lb_probe.http[0].port == 2480
    error_message = "Probe must be TCP on the HTTP port (/api/v1/ready answers 204, which an Azure HTTP probe counts as down)"
  }
  assert {
    condition     = azurerm_lb_rule.http[0].frontend_port == 2480 && azurerm_lb_rule.http[0].backend_port == 2480 && azurerm_lb_rule.http[0].protocol == "Tcp"
    error_message = "LB rule must be TCP 2480 -> 2480"
  }
  assert {
    condition     = length(azurerm_network_interface_backend_address_pool_association.node) == 3
    error_message = "All three NICs must be in the backend pool"
  }
  assert {
    condition     = azurerm_lb.this[0].tags["Cluster"] == "arcadedb-ha" && azurerm_lb.this[0].tags["Application"] == "ArcadeDB"
    error_message = "LB must be tagged"
  }
}

run "no_lb" {
  command = plan
  variables {
    enable_lb = false
  }
  assert {
    condition     = length(azurerm_lb.this) == 0 && length(azurerm_network_interface_backend_address_pool_association.node) == 0
    error_message = "No LB when enable_lb = false"
  }
  assert {
    condition     = output.lb_private_ip == null
    error_message = "lb_private_ip must be null without LB"
  }
  assert {
    condition     = output.studio_url == "http://node-0.arcadedb.internal:2480"
    error_message = "studio_url must use node-0's name without LB"
  }
}

run "no_password" {
  command = plan
  variables {
    arcadedb_root_password = ""
  }
  expect_failures = [var.arcadedb_root_password]
}

run "bad_password" {
  command = plan
  variables {
    arcadedb_root_password = "abcdefg'h"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "raft_rule" {
  command = plan
  assert {
    condition     = azurerm_network_security_rule.raft.destination_port_range == "2434" && azurerm_network_security_rule.raft.access == "Allow" && azurerm_network_security_rule.raft.direction == "Inbound"
    error_message = "NSG must allow Raft 2434 inbound"
  }
  assert {
    condition     = azurerm_network_security_rule.raft.source_application_security_group_ids == toset([azurerm_application_security_group.nodes.id]) && azurerm_network_security_rule.raft.destination_application_security_group_ids == toset([azurerm_application_security_group.nodes.id])
    error_message = "Raft rule must be scoped to the nodes' ASG on both ends"
  }
  assert {
    condition     = azurerm_network_security_rule.node_http.destination_port_range == "2480" && azurerm_network_security_rule.node_http.source_application_security_group_ids == toset([azurerm_application_security_group.nodes.id]) && azurerm_network_security_rule.node_http.destination_application_security_group_ids == toset([azurerm_application_security_group.nodes.id])
    error_message = "NSG must allow HTTP between the nodes' ASG"
  }
  assert {
    condition     = azurerm_network_security_rule.http.source_address_prefix == "10.0.0.0/16" && length(azurerm_network_security_rule.ssh) == 0
    error_message = "Clients from allowed_cidr, no SSH by default"
  }
  assert {
    condition     = length(azurerm_network_interface_application_security_group_association.node) == 3 && length(azurerm_network_interface_security_group_association.node) == 3
    error_message = "Every NIC must join the ASG and the NSG"
  }
}

run "arm" {
  command = plan
  variables {
    vm_size = "Standard_D2ps_v5"
  }
  assert {
    condition     = local.is_arm && alltrue([for vm in azurerm_linux_virtual_machine.node : vm.plan[0].name == "arcadedb-ubuntu-arm64"])
    error_message = "Arm64 sizes get the arm64 SKU"
  }
}

run "gallery_image" {
  command = plan
  variables {
    image_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal/images/arcadedb-ubuntu-x64/versions/26.11.1"
  }
  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.node : vm.source_image_id == var.image_id && length(vm.plan) == 0 && length(vm.source_image_reference) == 0])
    error_message = "Gallery image: source_image_id, no plan, no marketplace reference"
  }
}

run "gallery_arch_mismatch" {
  command = plan
  variables {
    image_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal/images/arcadedb-ubuntu-arm64/versions/26.11.1"
  }
  override_data {
    target = data.azurerm_shared_image.this
    values = {
      architecture = "Arm64"
    }
  }
  expect_failures = [azurerm_linux_virtual_machine.node]
}

run "tags" {
  command = plan
  variables {
    tags = { GitHubRun = "1" }
  }
  assert {
    condition = alltrue([for t in concat(
      [for vm in azurerm_linux_virtual_machine.node : vm.tags],
      [for n in azurerm_network_interface.node : n.tags],
      [for r in azurerm_private_dns_a_record.node : r.tags],
      [azurerm_network_security_group.this.tags, azurerm_application_security_group.nodes.tags, azurerm_private_dns_zone.this.tags, azurerm_private_dns_zone_virtual_network_link.this.tags, azurerm_lb.this[0].tags],
    ) : t["GitHubRun"] == "1" && t["Cluster"] == "arcadedb-ha" && t["Application"] == "ArcadeDB"])
    error_message = "Every taggable resource merges user tags with Cluster and Application"
  }
}

run "short_password" {
  command = plan
  variables {
    arcadedb_root_password = "Abc.123"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "min_length_password" {
  command = plan
  variables {
    arcadedb_root_password = "Abc.1234"
  }
  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.node : strcontains(base64decode(vm.custom_data), "path: /etc/arcadedb/root-password")])
    error_message = "An 8-character password must be accepted"
  }
}

run "max_ram_with_unit" {
  command = plan
  variables {
    arcadedb_max_ram = "2g"
  }
  expect_failures = [var.arcadedb_max_ram]
}

run "max_ram_zero" {
  command = plan
  variables {
    arcadedb_max_ram = "0"
  }
  expect_failures = [var.arcadedb_max_ram]
}

run "max_ram_custom" {
  command = plan
  variables {
    arcadedb_max_ram = "4096"
  }
  assert {
    condition     = alltrue([for vm in azurerm_linux_virtual_machine.node : strcontains(base64decode(vm.custom_data), "-Xmx4096m")])
    error_message = "arcadedb_max_ram must become -Xmx<MB>m on every node"
  }
}
