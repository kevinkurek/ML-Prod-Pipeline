#############################
# Core AWS infra (minimal)  #
#############################

locals { name = var.prefix }

# Simple VPC via registry module (public+private)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
  name    = "${local.name}-vpc"
  cidr    = "10.20.0.0/16"

  azs               = ["${var.region}a", "${var.region}b"]
  public_subnets    = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnets   = ["10.20.11.0/24", "10.20.12.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true
}

module "s3" {
  source = "./modules/s3"
  prefix = var.prefix
}

module "ecr" {
  source       = "./modules/ecr"
  repositories = ["condor-training", "condor-inference", "condor-batch"]
}

# Minimal ECS cluster (capacity providers can be added later)
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-ecs"
}

module "iam" {
  source = "./modules/iam"
  prefix = var.prefix
}

module "ecs" {
  source              = "./modules/ecs"
  name                = local.name
  vpc_id              = module.vpc.vpc_id
  private_subnet_ids  = module.vpc.private_subnets
  security_group_ids  = [] # not used by TF here; kept for future
  data_bucket_name    = module.s3.buckets["data"].name
  region              = var.region
}

############################################
# MWAA (inline, no external module)
############################################

# --- Data for ARNs we need in policies
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# --- MWAA execution role (customer-managed)
resource "aws_iam_role" "mwaa_exec" {
  name = "${var.prefix}-mwaa-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "airflow-env.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

# Single inline policy with the minimal permissions MWAA needs
resource "aws_iam_role_policy" "mwaa_all" {
  name = "${var.prefix}-mwaa-all"
  role = aws_iam_role.mwaa_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # S3 account/bucket Public Access Block reads + bucket metadata
      {
        Sid: "S3PABReads",
        Effect: "Allow",
        Action: [
          "s3:GetAccountPublicAccessBlock",
          "s3:GetBucketPublicAccessBlock",
          "s3:GetBucketLocation",
          "s3:GetBucketAcl"
        ],
        Resource: [
          "*",
          module.s3.buckets["mwaa_source"].arn
        ]
      },

      # List and read DAGs/plugins/requirements from your source bucket
      {
        Sid: "ListBucketForPaths",
        Effect: "Allow",
        Action: ["s3:ListBucket"],
        Resource: module.s3.buckets["mwaa_source"].arn,
        Condition: {
          StringLike: { "s3:prefix": [
            "dags/*","plugins/*","requirements/*","dags","plugins","requirements"
          ]}
        }
      },
      {
        Sid: "GetObjectsForPaths",
        Effect: "Allow",
        Action: ["s3:GetObject","s3:GetObjectVersion"],
        Resource: [
          "${module.s3.buckets["mwaa_source"].arn}/dags/*",
          "${module.s3.buckets["mwaa_source"].arn}/plugins/*",
          "${module.s3.buckets["mwaa_source"].arn}/requirements/*"
        ]
      },

      # CloudWatch Logs + Metrics
      {
        Sid: "CWL",
        Effect: "Allow",
        Action: [
          "logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents",
          "logs:GetLogEvents","logs:GetLogRecord","logs:GetQueryResults",
          "logs:DescribeLogGroups"
        ],
        Resource: "*"
      },
      {
        Sid: "CWPutMetrics",
        Effect: "Allow",
        Action: "cloudwatch:PutMetricData",
        Resource: "*"
      },

      # SQS Celery queue that MWAA creates (airflow-celery-*)
      {
        Sid: "SQSCelery",
        Effect: "Allow",
        Action: [
          "sqs:GetQueueAttributes","sqs:GetQueueUrl","sqs:ReceiveMessage",
          "sqs:DeleteMessage","sqs:SendMessage","sqs:ChangeMessageVisibility"
        ],
        Resource: "arn:aws:sqs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:airflow-celery-*"
      }
    ]
  })
}

# --- Networking SG for MWAA workers/scheduler/web (egress-only)
resource "aws_security_group" "mwaa" {
  name        = "${var.prefix}-mwaa-sg"
  description = "MWAA workers/web/scheduler egress"
  vpc_id      = module.vpc.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-mwaa-sg" }
}

# --- MWAA Environment
resource "aws_mwaa_environment" "this" {
  name               = "${var.prefix}-mwaa"
  airflow_version    = "3.0.6"       # latest supported in AWS as of now
  environment_class  = "mw1.medium"
  execution_role_arn = aws_iam_role.mwaa_exec.arn

  source_bucket_arn  = module.s3.buckets["mwaa_source"].arn
  dag_s3_path        = "dags"
  # Optional later:
  # plugins_s3_path      = "plugins.zip"
  # requirements_s3_path = "requirements/requirements.txt"

  network_configuration {
    security_group_ids = [aws_security_group.mwaa.id]
    subnet_ids         = module.vpc.private_subnets
  }

  logging_configuration {
    dag_processing_logs {
      enabled   = true
      log_level = "INFO"
    }
    scheduler_logs {
      enabled   = true
      log_level = "INFO"
    }
    task_logs {
      enabled   = true
      log_level = "INFO"
    }
    webserver_logs {
      enabled   = true
      log_level = "INFO"
    }
    worker_logs {
      enabled   = true
      log_level = "INFO"
    }
  }

  # Scale hints (or omit to use defaults)
  min_workers = 1
  max_workers = 2

  tags = {
    Name    = "${var.prefix}-mwaa"
    Project = var.prefix
  }
}
