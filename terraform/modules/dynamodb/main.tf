resource "aws_dynamodb_table" "ships" {
  name         = "${var.project_name}-ships"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ship_id"

  attribute {
    name = "ship_id"
    type = "S"
  }

  # Point-in-time recovery — restore to any second in the last 35 days
  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = var.common_tags
}

# Seed initial ship data via SSM — runs once after table creation
resource "aws_ssm_parameter" "dynamodb_table" {
  name  = "/${var.project_name}/production/dynamodb_ships_table"
  type  = "String"
  value = aws_dynamodb_table.ships.name
  tags  = var.common_tags
}
