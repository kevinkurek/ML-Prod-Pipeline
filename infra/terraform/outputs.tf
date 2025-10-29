output "data_bucket" { value = module.s3.buckets["data"].name }
output "artifacts_bucket" { value = module.s3.buckets["artifacts"].name }
output "logs_bucket" { value = module.s3.buckets["logs"].name }
output "ecs_cluster_arn" { value = aws_ecs_cluster.this.arn }

# SageMaker execution role ARN (used by training and endpoint creation)
output "sagemaker_role_arn" {
  value       = module.iam.sagemaker_role_arn
  description = "IAM Role ARN for SageMaker training and inference"
}

# output "features_task_def_arn"  { value = module.ecs.features_task_def_arn }
# output "private_subnets"        { value = module.vpc.private_subnet_ids }
# output "ecs_security_group_ids" { value = module.ecs.security_group_ids }