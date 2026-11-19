mock_provider "azurerm" {
  override_data {
    target = data.azurerm_resource_group.this
    values = {
      location = "eastus"
    }
  }

  override_data {
    target = data.azurerm_shared_image.this
    values = {
      architecture = "x64"
    }
  }
}

variables {
  resource_group_name  = "rg-test"
  subnet_id            = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test/providers/Microsoft.Network/virtualNetworks/vnet-test/subnets/snet-test"
  admin_ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCvJ9TOr4PX2ScseRc57qAtVrIvruGzWAZ5MHTh/S4jX4J0VeYfoh8qAzPXCASOt2bTOrI1XmhSXON+nuWNt93nBop4FAA65e3I76iMti1gu8fBuzkRQ2XQxhmJM+lquw8V6hb4op+LAWhq7ZNh8DvIZQwuuVd+QA5/qgjO6EHuLD4dsJSKsV72XKgUIaIjb0CEevwkqG61zmZnp2l419gKuAf5y2AqKqfIdHjHgLAQXf73rMv6+n1tg7ZcxrUmHFcgY3S9lW0JDJ///zYwF4HmDm7CP8JWW2mbX5/SMAlJj6XcRVz+JgYn++ddbaY21szI2vPEAqt/IWiWMUZHh0X/ test"
  allowed_cidr         = "10.0.0.0/16"
}

run "x64_marketplace" {
  command = plan

  assert {
    condition     = local.marketplace_sku == "arcadedb-ubuntu"
    error_message = "x64 default must use the arcadedb-ubuntu SKU"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.plan[0].name == "arcadedb-ubuntu" && azurerm_linux_virtual_machine.this.plan[0].publisher == "arcadedb" && azurerm_linux_virtual_machine.this.plan[0].product == "arcadedb"
    error_message = "Marketplace plan must be arcadedb/arcadedb/<sku>"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_reference[0].version == "latest" && azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "arcadedb-ubuntu"
    error_message = "Marketplace image must default to version latest"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.secure_boot_enabled && azurerm_linux_virtual_machine.this.vtpm_enabled
    error_message = "Trusted launch must be on"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.disable_password_authentication
    error_message = "Password authentication must be off"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.location == "eastus"
    error_message = "Location must default to the resource group's"
  }
}

run "arm_d2ps" {
  command = plan
  variables {
    vm_size = "Standard_D2ps_v5"
  }
  assert {
    condition     = local.is_arm && local.marketplace_sku == "arcadedb-ubuntu-arm64" && azurerm_linux_virtual_machine.this.plan[0].name == "arcadedb-ubuntu-arm64"
    error_message = "Standard_D2ps_v5 is Arm64"
  }
}

run "arm_d4pds" {
  command = plan
  variables {
    vm_size = "Standard_D4pds_v5"
  }
  assert {
    condition     = local.is_arm && local.marketplace_sku == "arcadedb-ubuntu-arm64"
    error_message = "Standard_D4pds_v5 is Arm64"
  }
}

run "arm_e2ps" {
  command = plan
  variables {
    vm_size = "Standard_E2ps_v5"
  }
  assert {
    condition     = local.is_arm && local.marketplace_sku == "arcadedb-ubuntu-arm64"
    error_message = "Standard_E2ps_v5 is Arm64"
  }
}

run "arm_d2pls" {
  command = plan
  variables {
    vm_size = "Standard_D2pls_v5"
  }
  assert {
    condition     = local.is_arm
    error_message = "Standard_D2pls_v5 is Arm64"
  }
}

run "x64_d2s_v5" {
  command = plan
  variables {
    vm_size = "Standard_D2s_v5"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_D2s_v5 is x64"
  }
}

run "x64_d2s_v4" {
  command = plan
  variables {
    vm_size = "Standard_D2s_v4"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_D2s_v4 is x64"
  }
}

run "x64_d2as_v5" {
  command = plan
  variables {
    vm_size = "Standard_D2as_v5"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_D2as_v5 is x64"
  }
}

run "x64_e4ds_v5" {
  command = plan
  variables {
    vm_size = "Standard_E4ds_v5"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_E4ds_v5 is x64"
  }
}

run "x64_b2ms" {
  command = plan
  variables {
    vm_size = "Standard_B2ms"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_B2ms is x64"
  }
}

run "x64_f4s_v2" {
  command = plan
  variables {
    vm_size = "Standard_F4s_v2"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_F4s_v2 is x64"
  }
}

run "arm_d2ps_v6" {
  command = plan
  variables {
    vm_size = "Standard_D2ps_v6"
  }
  assert {
    condition     = local.is_arm
    error_message = "Standard_D2ps_v6 is Arm64"
  }
}

run "x64_b1s" {
  command = plan
  variables {
    vm_size = "Standard_B1s"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_B1s is x64"
  }
}

run "x64_dc2s_v3" {
  command = plan
  variables {
    vm_size = "Standard_DC2s_v3"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_DC2s_v3 is x64"
  }
}

run "x64_e2bds_v5" {
  command = plan
  variables {
    vm_size = "Standard_E2bds_v5"
  }
  assert {
    condition     = !local.is_arm
    error_message = "Standard_E2bds_v5 is x64"
  }
}

run "gallery_image" {
  command = plan
  variables {
    image_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal/images/arcadedb-ubuntu-x64/versions/26.11.1"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.source_image_id == var.image_id
    error_message = "image_id must be used as source_image_id"
  }
  assert {
    condition     = length(azurerm_linux_virtual_machine.this.plan) == 0 && length(azurerm_linux_virtual_machine.this.source_image_reference) == 0
    error_message = "Gallery images take no plan and no marketplace reference"
  }
}

run "gallery_arch_mismatch" {
  command = plan
  variables {
    image_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-images/providers/Microsoft.Compute/galleries/gal/images/arcadedb-ubuntu-arm64/versions/26.11.1"
    vm_size  = "Standard_D2s_v5"
  }
  override_data {
    target = data.azurerm_shared_image.this
    values = {
      architecture = "Arm64"
    }
  }
  expect_failures = [azurerm_linux_virtual_machine.this]
}

run "no_password_keeps_image_password" {
  command = plan
  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "path: /etc/arcadedb/root-password")
    error_message = "No root-password file may be written when no password is set"
  }
  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "server-users.jsonl")
    error_message = "The users file must be left alone when no password is set"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "rootPasswordPath=/etc/arcadedb/root-password")
    error_message = "Settings must keep rootPasswordPath"
  }
}

run "password_set" {
  command = plan
  variables {
    arcadedb_root_password = "Test.Pass-1"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "path: /etc/arcadedb/root-password")
    error_message = "Password file must be written"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "rootPasswordPath")
    error_message = "Settings must point at the password file"
  }
  assert {
    condition     = !strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "rootPassword=")
    error_message = "The password must never be a -D option"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "server-users.jsonl")
    error_message = "A stale users file must be removed when a password is set"
  }
  assert {
    condition     = strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "0600") && strcontains(base64decode(azurerm_linux_virtual_machine.this.custom_data), "arcadedb:arcadedb")
    error_message = "Password file must be 0600 and owned by the arcadedb service user"
  }
}

run "bad_password_quote" {
  command = plan
  variables {
    arcadedb_root_password = "a'b"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "bad_password_dollar" {
  command = plan
  variables {
    arcadedb_root_password = "a$b"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "bad_password_space" {
  command = plan
  variables {
    arcadedb_root_password = "a b"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "bad_password_percent" {
  command = plan
  variables {
    arcadedb_root_password = "a%b"
  }
  expect_failures = [var.arcadedb_root_password]
}

run "ssh_rule_off" {
  command = plan
  assert {
    condition     = length(azurerm_network_security_rule.ssh) == 0
    error_message = "No SSH rule unless enable_ssh"
  }
  assert {
    condition     = azurerm_network_security_rule.http.destination_port_range == "2480" && azurerm_network_security_rule.http.source_address_prefix == "10.0.0.0/16"
    error_message = "HTTP rule must allow allowed_cidr on the HTTP port"
  }
}

run "ssh_rule_on" {
  command = plan
  variables {
    enable_ssh = true
  }
  assert {
    condition     = length(azurerm_network_security_rule.ssh) == 1 && azurerm_network_security_rule.ssh[0].destination_port_range == "22" && azurerm_network_security_rule.ssh[0].source_address_prefix == var.allowed_cidr
    error_message = "SSH rule must allow allowed_cidr on 22"
  }
}

run "public_ip" {
  command = plan
  variables {
    public_ip = true
  }
  assert {
    condition     = length(azurerm_public_ip.this) == 1 && azurerm_public_ip.this[0].sku == "Standard" && azurerm_public_ip.this[0].allocation_method == "Static"
    error_message = "Public IP must be Standard static"
  }
}

run "tags" {
  command = plan
  variables {
    tags = { GitHubRun = "1" }
  }
  assert {
    condition     = azurerm_linux_virtual_machine.this.tags["GitHubRun"] == "1" && azurerm_linux_virtual_machine.this.tags["Cluster"] == "arcadedb" && azurerm_linux_virtual_machine.this.tags["Application"] == "ArcadeDB"
    error_message = "VM tags must merge user tags with Cluster and Application"
  }
}
