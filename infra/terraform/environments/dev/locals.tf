data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  eks_cluster_role_arn = var.create_iam_roles ? aws_iam_role.eks_cluster[0].arn : var.cluster_role_arn
  eks_node_role_arn    = var.create_iam_roles ? aws_iam_role.eks_nodes[0].arn : var.node_role_arn

  eks_node_subnet_ids = var.use_public_node_group_subnets ? module.networking.public_subnet_ids : module.networking.private_subnet_ids

  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
      Phase       = "3"
    },
    var.tags
  )

  rds_instances = {
    auth = {
      identifier          = "${local.name_prefix}-auth-db"
      db_name             = "auth_db"
      username            = "auth_admin"
      instance_class      = var.rds_instance_class
      allocated_storage   = 20
      engine_version      = var.rds_engine_version
      multi_az            = false
      publicly_accessible = false
    }
    flag = {
      identifier          = "${local.name_prefix}-flag-db"
      db_name             = "flags_db"
      username            = "flag_admin"
      instance_class      = var.rds_instance_class
      allocated_storage   = 20
      engine_version      = var.rds_engine_version
      multi_az            = false
      publicly_accessible = false
    }
    targeting = {
      identifier          = "${local.name_prefix}-targeting-db"
      db_name             = "targeting_db"
      username            = "targeting_admin"
      instance_class      = var.rds_instance_class
      allocated_storage   = 20
      engine_version      = var.rds_engine_version
      multi_az            = false
      publicly_accessible = false
    }
  }

  node_groups = {
    default = {
      desired_size   = 1
      max_size       = 2
      min_size       = 1
      instance_types = var.node_group_instance_types
      capacity_type  = "ON_DEMAND"
      disk_size      = 20
    }
  }
}
