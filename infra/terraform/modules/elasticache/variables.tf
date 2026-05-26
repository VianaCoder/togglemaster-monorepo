variable "name_prefix" {
  description = "Prefix used in resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where Redis security group is created"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs used by Redis subnet group"
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to connect to Redis"
  type        = list(string)
  default     = []
}

variable "node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "engine_version" {
  description = "Redis engine version"
  type        = string
  default     = "7.1"
}

variable "port" {
  description = "Redis port"
  type        = number
  default     = 6379
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
