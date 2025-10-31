variable "prefix" { type = string }

data "aws_iam_policy_document" "assume_sagemaker" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker_exec" {
  name               = "${var.prefix}-sagemaker-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_sagemaker.json
}

# Keep these (broad but fine in a sandbox)
resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "sagemaker_s3" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

# ✅ Add this inline policy: ECR pull + CloudWatch Logs at runtime
resource "aws_iam_role_policy" "sagemaker_runtime" {
  name = "${var.prefix}-sagemaker-runtime"
  role = aws_iam_role.sagemaker_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        "Sid" : "EcrPull",
        "Effect" : "Allow",
        "Action" : [
          "ecr:GetAuthorizationToken",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchCheckLayerAvailability"
        ],
        "Resource" : "*"
      },
      {
        "Sid" : "Logs",
        "Effect" : "Allow",
        "Action" : [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ],
        "Resource" : "*"
      }
    ]
  })
}

output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker_exec.arn
}