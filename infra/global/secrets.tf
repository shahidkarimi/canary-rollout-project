resource "random_password" "initial_token" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "token" {
  name       = "/dockyard/SUPER_SECRET_TOKEN"
  kms_key_id = aws_kms_key.main.arn

  recovery_window_in_days = 0 # demo: allow immediate delete on teardown
}

resource "aws_secretsmanager_secret_version" "initial" {
  secret_id     = aws_secretsmanager_secret.token.id
  secret_string = "dkyd_${random_password.initial_token.result}"

  lifecycle {
    # Rotation creates new versions outside Terraform; never fight it.
    ignore_changes = [secret_string]
  }
}

# ---------------------------------------------------------------------------
# Rotation function (random-token rotator) + 30-day schedule
# ---------------------------------------------------------------------------
data "archive_file" "rotation" {
  type        = "zip"
  source_file = "${path.module}/rotation/handler.py"
  output_path = "${path.module}/rotation/handler.zip"
}

data "aws_iam_policy_document" "rotation_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rotation" {
  name               = "${var.project}-secret-rotation"
  assume_role_policy = data.aws_iam_policy_document.rotation_trust.json
}

resource "aws_iam_role_policy_attachment" "rotation_logs" {
  role       = aws_iam_role.rotation.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "rotation" {
  statement {
    actions = [
      "secretsmanager:DescribeSecret",
      "secretsmanager:GetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = [aws_secretsmanager_secret.token.arn]
  }

  statement {
    actions   = ["secretsmanager:GetRandomPassword"]
    resources = ["*"]
  }

  statement {
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "rotation" {
  name   = "rotation"
  role   = aws_iam_role.rotation.id
  policy = data.aws_iam_policy_document.rotation.json
}

resource "aws_lambda_function" "rotation" {
  function_name    = "${var.project}-secret-rotation"
  role             = aws_iam_role.rotation.arn
  handler          = "handler.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.rotation.output_path
  source_code_hash = data.archive_file.rotation.output_base64sha256
  timeout          = 30
}

resource "aws_lambda_permission" "rotation" {
  statement_id  = "AllowSecretsManager"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotation.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.token.arn
}

resource "aws_secretsmanager_secret_rotation" "token" {
  secret_id           = aws_secretsmanager_secret.token.id
  rotation_lambda_arn = aws_lambda_function.rotation.arn

  rotation_rules {
    automatically_after_days = 30
  }

  depends_on = [aws_lambda_permission.rotation]
}
