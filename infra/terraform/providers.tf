terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "profile" {
  type    = string
  default = "kevin_sandbox"
}

provider "aws" {
  region  = var.region
  profile = var.profile
}