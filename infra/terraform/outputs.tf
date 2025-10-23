output "data_bucket" { value = module.s3.buckets["data"].name }
output "artifacts_bucket" { value = module.s3.buckets["artifacts"].name }
output "logs_bucket" { value = module.s3.buckets["logs"].name }
output "ecs_cluster_arn" { value = aws_ecs_cluster.this.arn }
