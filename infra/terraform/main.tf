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

  azs             = ["${var.region}a", "${var.region}b"]
  public_subnets  = ["10.20.1.0/24", "10.20.2.0/24"]
  private_subnets = ["10.20.11.0/24", "10.20.12.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
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

# (Optional) MWAA & SageMaker extras can be added as separate modules later.
# You can set MWAA variables/connection via console or TF if you add a module.
