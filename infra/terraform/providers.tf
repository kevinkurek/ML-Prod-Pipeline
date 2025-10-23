terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.3.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
}

provider "github" {
  owner = var.github_owner
}