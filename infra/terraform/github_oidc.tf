# ============================================================
# EXPLANATION:
# OpenID Connect (OIDC) lets GitHub Actions authenticate to AWS
# *without* storing long-lived AWS keys in GitHub secrets.
# AWS trusts GitHub’s OIDC identity provider, which issues short-lived
# tokens to GitHub workflows. Those tokens let a workflow assume
# a specific IAM role in your AWS account.
# ============================================================

# EXPLANATION: Input variables for GitHub repository and branch.
# You can override these via CLI (-var) or tfvars for different repos.
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

# EXPLANATION: Defines GitHub’s public OIDC provider inside AWS IAM.
# This allows AWS to trust identity tokens coming from GitHub Actions.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# EXPLANATION: Builds a trust policy that allows the OIDC provider
# to assume a specific IAM role only when the token matches your
# repo + branch (to limit access to authorized workflows).
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

# EXPLANATION: Creates the IAM role GitHub Actions will assume.
# It uses the above trust policy to restrict which tokens are valid.
resource "aws_iam_role" "gha_ecr_push" {
  name               = "${var.prefix}-gha-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# EXPLANATION: Defines permissions needed to push container images
# to Amazon ECR (create repo, upload layers, push images, etc.).
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

# EXPLANATION: Attaches the ECR push policy to the GitHub Actions role.
resource "aws_iam_role_policy" "ecr_push" {
  role   = aws_iam_role.gha_ecr_push.id
  policy = data.aws_iam_policy_document.ecr_push.json
}

# EXPLANATION: Outputs the ARN of the role (for debugging or reuse).
output "gha_role_arn" {
  value = aws_iam_role.gha_ecr_push.arn
}

# EXPLANATION: Publishes the role ARN to your GitHub repository as a
# GitHub Actions variable named AWS_ROLE_TO_ASSUME, so your workflow
# can reference it directly when assuming the role.
resource "github_actions_variable" "aws_role_to_assume" {
  repository    = var.github_repo
  variable_name = "AWS_ROLE_TO_ASSUME"
  value         = aws_iam_role.gha_ecr_push.arn
}