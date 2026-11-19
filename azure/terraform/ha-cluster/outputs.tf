output "lb_private_ip" {
  description = "Private IP of the internal load balancer (null when enable_lb = false)"
  value       = var.enable_lb ? azurerm_lb.this[0].frontend_ip_configuration[0].private_ip_address : null
}

output "vm_ids" {
  description = "Resource IDs of node-0..node-2"
  value       = azurerm_linux_virtual_machine.node[*].id
}

output "vm_names" {
  description = "VM names of node-0..node-2"
  value       = azurerm_linux_virtual_machine.node[*].name
}

output "private_ips" {
  description = "Static private IPs of node-0..node-2"
  value       = [for nic in azurerm_network_interface.node : nic.ip_configuration[0].private_ip_address]
}

output "node_dns_names" {
  description = "node-N.<zone> names of node-0..node-2"
  value       = local.node_dns_names
}

output "studio_url" {
  description = "ArcadeDB Studio URL: the load balancer, or node-0 when enable_lb = false"
  value       = "http://${var.enable_lb ? azurerm_lb.this[0].frontend_ip_configuration[0].private_ip_address : local.node_dns_names[0]}:${var.arcadedb_http_port}"
}

output "zone_name" {
  description = "Private DNS zone name"
  value       = azurerm_private_dns_zone.this.name
}

output "nsg_id" {
  description = "Network security group ID of the nodes"
  value       = azurerm_network_security_group.this.id
}
