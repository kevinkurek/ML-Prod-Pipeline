variable "prefix" { type = string }
resource "aws_s3_bucket" "data" { bucket = "${var.prefix}-data-${random_id.sfx.hex}" }
resource "aws_s3_bucket" "artifacts" { bucket = "${var.prefix}-artifacts-${random_id.sfx.hex}" }
resource "aws_s3_bucket" "logs" { bucket = "${var.prefix}-logs-${random_id.sfx.hex}" }

resource "random_id" "sfx" { byte_length = 3 }

output "buckets" {
  value = {
    data      = { name = aws_s3_bucket.data.bucket }
    artifacts = { name = aws_s3_bucket.artifacts.bucket }
    logs      = { name = aws_s3_bucket.logs.bucket }
  }
}
