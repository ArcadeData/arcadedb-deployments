output "instance_id" {
  description = "Instance ID of ArcadeDB server"
  value       = aws_instance.arcadedb.id
}

output "public_ip" {
  description = "Public IP address of ArcadeDB server"
  value       = aws_instance.arcadedb.public_ip
}

output "private_ip" {
  description = "Private IP address of ArcadeDB server"
  value       = aws_instance.arcadedb.private_ip
}

output "studio_url" {
  description = "URL for ArcadeDB Studio"
  value       = "http://${aws_instance.arcadedb.public_ip}:${var.arcadedb_http_port}"
}

output "api_url" {
  description = "URL for ArcadeDB API"
  value       = "http://${aws_instance.arcadedb.public_ip}:${var.arcadedb_http_port}/api/v1"
}

output "security_group_id" {
  description = "Security Group ID"
  value       = local.security_group_id
}

output "ssh_command" {
  description = "SSH command to connect to instance"
  value       = "ssh -i your-key.pem ubuntu@${aws_instance.arcadedb.public_ip}"
}
