locals {
  common_tags = merge(var.tags, {
    Module = "elasticache"
  })
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-redis-subnet-group"
  subnet_ids = var.subnet_ids

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis-subnet-group"
  })
}

resource "aws_security_group" "this" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Security group for ToggleMaster Redis"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = length(var.allowed_cidr_blocks) > 0 ? [1] : []
    content {
      from_port   = var.port
      to_port     = var.port
      protocol    = "tcp"
      cidr_blocks = var.allowed_cidr_blocks
      description = "Redis access"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis-sg"
  })
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = "${var.name_prefix}-redis"
  description                = "ToggleMaster Redis"
  engine                     = "redis"
  engine_version             = var.engine_version
  node_type                  = var.node_type
  port                       = var.port
  parameter_group_name       = "default.redis7"
  automatic_failover_enabled = false
  num_cache_clusters         = 1

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.this.id]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-redis"
  })
}
