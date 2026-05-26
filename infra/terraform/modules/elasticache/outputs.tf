output "security_group_id" {
  description = "Security group ID used by Redis"
  value       = aws_security_group.this.id
}

output "primary_endpoint_address" {
  description = "Primary Redis endpoint"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Reader Redis endpoint"
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}
