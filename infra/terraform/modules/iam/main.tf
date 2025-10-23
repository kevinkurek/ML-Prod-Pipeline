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

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

resource "aws_iam_role_policy_attachment" "sagemaker_s3" {
  role       = aws_iam_role.sagemaker_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

output "sagemaker_role_arn" {
  value = aws_iam_role.sagemaker_exec.arn
}