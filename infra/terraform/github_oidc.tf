# ============================================================
# GitHub OIDC role for GitHub Actions to push to ECR
# ============================================================

# --- Inputs you can override via -var or tfvars ---
variable "github_owner" {
  type    = string
  default = "kevinkurek"
}

variable "github_repo" {
  type    = string
  default = "ML-Prod-Pipeline"
}

variable "github_branch" {
  type    = string
  default = "main"
}

# --- GitHub OIDC provider in AWS ---
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# --- Trust policy ---
data "aws_iam_policy_document" "gha_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_branch}"
      ]
    }
  }
}

# --- IAM Role ---
resource "aws_iam_role" "gha_ecr_push" {
  name               = "${var.prefix}-gha-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# --- Policy to push to ECR ---
data "aws_iam_policy_document" "ecr_push" {
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:DescribeRepositories",
      "ecr:CreateRepository"
    ]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecr_push" {
  role   = aws_iam_role.gha_ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

output "gha_role_arn" {
  value = aws_iam_role.gha_ecr_push.arn
}

# --- Publish role ARN to GitHub Actions variables ---
resource "github_actions_variable" "aws_role_to_assume" {
  repository    = var.github_repo
  variable_name = "AWS_ROLE_TO_ASSUME"
  value         = aws_iam_role.gha_ecr_push.arn
}