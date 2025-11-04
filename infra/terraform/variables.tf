variable "prefix" {
  description = "Prefix for resource names (e.g. condor, ml-prod-pipeline)"
  type        = string
}

variable "region" {
  description = "AWS region to deploy resources in"
  type        = string
}

variable "profile" {
  description = "AWS CLI profile to use for authentication"
  type        = string
  default     = "kevin_sandbox"
}

variable "tags" {
  description = "Default tags to apply to all resources"
  type        = map(string)
  default     = {}
}