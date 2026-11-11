output "nlb_dns_name" {
  description = "DNS name of the internal Network Load Balancer (null when enable_nlb = false)"
  value       = var.enable_nlb ? aws_lb.nlb[0].dns_name : null
}

output "instance_ids" {
  description = "Instance IDs of node-0, node-1, node-2 (in that order)"
  value       = aws_instance.node[*].id
}

output "private_ips" {
  description = "Private IP addresses of node-0, node-1, node-2 (in that order)"
  value       = aws_network_interface.node[*].private_ip
}

output "network_interface_ids" {
  description = "Primary ENI IDs of node-0, node-1, node-2 (in that order); they outlive instance replacement"
  value       = aws_network_interface.node[*].id
}

output "public_ips" {
  description = "Elastic IPs of node-0, node-1, node-2 (empty when associate_public_ip = false)"
  value       = aws_eip.node[*].public_ip
}

output "node_dns_names" {
  description = "DNS names of node-0, node-1, node-2 in the private hosted zone (resolvable only inside the VPC)"
  value       = local.node_dns_names
}

output "studio_url" {
  description = "URL for ArcadeDB Studio: the NLB when enabled, otherwise node-0 (reachable only inside the VPC)"
  value       = var.enable_nlb ? "http://${aws_lb.nlb[0].dns_name}:${local.http_port}" : "http://${local.node_dns_names[0]}:${local.http_port}"
}

output "zone_name" {
  description = "Name of the Route 53 private hosted zone"
  value       = aws_route53_zone.private.name
}

output "zone_id" {
  description = "ID of the Route 53 private hosted zone"
  value       = aws_route53_zone.private.zone_id
}

output "security_group_id" {
  description = "ID of the security group shared by the nodes"
  value       = aws_security_group.node.id
}
