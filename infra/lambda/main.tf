# ---------------------------------------------------------------------------
# Lambda from the ECR image (most recent at first apply; afterwards the
# pipeline owns code updates and CodeDeploy owns the alias -> ignore_changes).
# ---------------------------------------------------------------------------
data "aws_ecr_image" "latest" {
  repository_name = "${var.project}/podinfo"
  most_recent     = true
}

data "aws_iam_policy_document" "lambda_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "exec" {
  name               = "${local.name}-podinfo-exec"
  assume_role_policy = data.aws_iam_policy_document.lambda_trust.json
}

resource "aws_iam_role_policy_attachment" "exec_logs" {
  role       = aws_iam_role.exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "exec" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.secret_arn]
  }

  statement {
    actions   = ["kms:Decrypt"]
    resources = [local.global.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "exec" {
  name   = "podinfo"
  role   = aws_iam_role.exec.id
  policy = data.aws_iam_policy_document.exec.json
}

resource "aws_cloudwatch_log_group" "fn" {
  name              = "/aws/lambda/${local.name}-podinfo"
  retention_in_days = 14
}

resource "aws_lambda_function" "podinfo" {
  function_name = "${local.name}-podinfo"
  role          = aws_iam_role.exec.arn
  package_type  = "Image"
  image_uri     = "${local.global.ecr_repository_url}@${data.aws_ecr_image.latest.image_digest}"
  architectures = ["x86_64"]
  memory_size   = 256
  timeout       = 10
  publish       = true

  environment {
    variables = {
      SECRET_ARN  = local.secret_arn
      ENVIRONMENT = var.env
    }
  }

  lifecycle {
    # The pipeline pushes new digests via UpdateFunctionCode; Terraform must
    # not revert them on later applies (drift tolerance by design).
    ignore_changes = [image_uri]
  }

  depends_on = [aws_cloudwatch_log_group.fn]
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.podinfo.function_name
  function_version = aws_lambda_function.podinfo.version

  lifecycle {
    # CodeDeploy shifts this alias between versions during canary releases.
    ignore_changes = [function_version, routing_config]
  }
}

resource "aws_lambda_provisioned_concurrency_config" "live" {
  count                             = var.provisioned_concurrency > 0 ? 1 : 0
  function_name                     = aws_lambda_function.podinfo.function_name
  qualifier                         = aws_lambda_alias.live.name
  provisioned_concurrent_executions = var.provisioned_concurrency
}
