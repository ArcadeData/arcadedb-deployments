output "vm_id" {
  description = "Resource ID of the ArcadeDB VM"
  value       = azurerm_linux_virtual_machine.this.id
}

output "vm_name" {
  description = "Name of the ArcadeDB VM"
  value       = azurerm_linux_virtual_machine.this.name
}

output "private_ip" {
  description = "Private IP address of the VM"
  value       = azurerm_network_interface.this.private_ip_address
}

output "public_ip" {
  description = "Public IP address of the VM (null without public_ip)"
  value       = var.public_ip ? azurerm_public_ip.this[0].ip_address : null
}

output "studio_url" {
  description = "URL for ArcadeDB Studio"
  value       = "http://${var.public_ip ? azurerm_public_ip.this[0].ip_address : azurerm_network_interface.this.private_ip_address}:${var.arcadedb_http_port}"
}

output "admin_username" {
  description = "Administrator user for SSH"
  value       = var.admin_username
}

output "root_password_hint" {
  description = "Where to read the ArcadeDB root password"
  value       = nonsensitive(var.arcadedb_root_password != "") ? "The password set in arcadedb_root_password (user root)." : "Generated on first boot: ssh to the VM and run `cat ~/arcadedb-root-password.txt` (user root)."
}
