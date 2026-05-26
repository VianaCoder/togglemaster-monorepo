locals {
  common_tags = merge(var.tags, {
    Module = "dynamodb"
  })
}

resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = var.billing_mode
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  tags = merge(local.common_tags, {
    Name = var.table_name
  })
}
