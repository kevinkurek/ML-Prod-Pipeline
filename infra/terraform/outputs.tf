output "data_bucket" { value = module.s3.buckets["data"].name }
output "artifacts_bucket" { value = module.s3.buckets["artifacts"].name }
output "logs_bucket" { value = module.s3.buckets["logs"].name }
output "ecs_cluster_arn" { value = aws_ecs_cluster.this.arn }

# SageMaker execution role ARN (used by training and endpoint creation)
output "sagemaker_role_arn" {
  value       = module.iam.sagemaker_role_arn
  description = "IAM Role ARN for SageMaker training and inference"
}
