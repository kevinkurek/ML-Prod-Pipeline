variable "prefix" {
  type = string
}

variable "force_destroy" {
  description = "Allow Terraform to delete non-empty buckets on destroy (careful in prod)"
  type        = bool
  default     = false
}

resource "random_id" "sfx" {
  byte_length = 3
}

locals {
  bucket_keys = toset(["data", "artifacts", "logs", "mwaa-source"])

  # Build final bucket names: <prefix>-<key>-<hex>
  bucket_names = {
    for k in local.bucket_keys :
    k => "${var.prefix}-${k}-${random_id.sfx.hex}"
  }

  common_tags = {
    Project = var.prefix
    Managed = "terraform"
  }
}

# -------------------------
# Buckets (one loop, four)
# -------------------------
resource "aws_s3_bucket" "b" {
  for_each = local.bucket_names
  bucket   = each.value
  force_destroy = var.force_destroy

  tags = merge(local.common_tags, {
    Name    = each.value
    Purpose = each.key
  })
}

# Encryption (SSE-S3) for all
resource "aws_s3_bucket_server_side_encryption_configuration" "b" {
  for_each = aws_s3_bucket.b
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning for all
resource "aws_s3_bucket_versioning" "b" {
  for_each = aws_s3_bucket.b
  bucket   = each.value.id
  versioning_configuration { 
    status = "Enabled" 
  }
}

# Block public access for all
resource "aws_s3_bucket_public_access_block" "b" {
  for_each                = aws_s3_bucket.b
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Simple lifecycle for logs (expire after 90 days)
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.b["logs"].id

  rule {
    id     = "expire-logs-90d"
    status = "Enabled"
    
    filter {
      prefix = ""
    }

    expiration {
      days = 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# -------------------------
# Outputs
# -------------------------
output "buckets" {
  value = {
    data        = { name = aws_s3_bucket.b["data"].bucket,        arn = aws_s3_bucket.b["data"].arn }
    artifacts   = { name = aws_s3_bucket.b["artifacts"].bucket,   arn = aws_s3_bucket.b["artifacts"].arn }
    logs        = { name = aws_s3_bucket.b["logs"].bucket,        arn = aws_s3_bucket.b["logs"].arn }
    mwaa_source = { name = aws_s3_bucket.b["mwaa-source"].bucket, arn = aws_s3_bucket.b["mwaa-source"].arn }
  }
}

output "data_bucket"        { value = aws_s3_bucket.b["data"].bucket }
output "artifacts_bucket"   { value = aws_s3_bucket.b["artifacts"].bucket }
output "logs_bucket"        { value = aws_s3_bucket.b["logs"].bucket }
output "mwaa_source_bucket" { value = aws_s3_bucket.b["mwaa-source"].bucket }