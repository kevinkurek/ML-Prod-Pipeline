# ============================================================
# GitHub OIDC role for GitHub Actions to push to ECR
# ============================================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # GitHub OIDC root CA
}

# Allow only your repo & branch to assume the role
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
      values   = [
        # 👇 replace with your GitHub org/user and repo name
        "repo:theinfinityfund/ml-prod-pipeline:ref:refs/heads/main"
      ]
    }
  }
}

# IAM role GitHub Actions will assume
resource "aws_iam_role" "gha_ecr_push" {
  name               = "${var.prefix}-gha-ecr-push"
  assume_role_policy = data.aws_iam_policy_document.gha_assume.json
}

# Permissions to push to ECR
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
    effect = "Allow"
    actions = ["sts:GetCallerIdentity"]
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