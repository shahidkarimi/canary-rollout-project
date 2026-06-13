resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

# ---------------------------------------------------------------------------
# ci-build: push images to the single ECR repo. Trust: main branch only.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "build_trust" {
  statement {
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_build" {
  name               = "${var.project}-ci-build"
  assume_role_policy = data.aws_iam_policy_document.build_trust.json
}

data "aws_iam_policy_document" "ci_build" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.podinfo.arn]
  }

  statement {
    sid       = "EcrKms"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "ci_build" {
  name   = "ci-build"
  role   = aws_iam_role.ci_build.id
  policy = data.aws_iam_policy_document.ci_build.json
}

# ---------------------------------------------------------------------------
# ci-deploy: drive CodeDeploy/Lambda/ALB releases. Trust: GitHub environments
# dev/prod only (the prod environment enforces the human approval gate).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "deploy_trust" {
  statement {
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
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:environment:dev",
        "repo:${var.github_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "ci_deploy" {
  name               = "${var.project}-ci-deploy"
  assume_role_policy = data.aws_iam_policy_document.deploy_trust.json
}

data "aws_iam_policy_document" "ci_deploy" {
  statement {
    sid = "CodeDeploy"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetApplication",
      "codedeploy:GetApplicationRevision",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:GetDeploymentTarget",
      "codedeploy:ListDeploymentTargets",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:StopDeployment",
    ]
    resources = [
      "arn:aws:codedeploy:${var.region}:${local.account_id}:application:${var.project}-*",
      "arn:aws:codedeploy:${var.region}:${local.account_id}:deploymentgroup:${var.project}-*/*",
      "arn:aws:codedeploy:${var.region}:${local.account_id}:deploymentconfig:*",
    ]
  }

  statement {
    sid = "LambdaRelease"
    actions = [
      "lambda:GetAlias",
      "lambda:GetFunction",
      "lambda:GetFunctionConfiguration",
      "lambda:ListVersionsByFunction",
      "lambda:PublishVersion",
      "lambda:UpdateFunctionCode",
    ]
    resources = ["arn:aws:lambda:${var.region}:${local.account_id}:function:${var.project}-*"]
  }

  statement {
    sid       = "RevisionBucket"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.revisions.arn}/*"]
  }

  statement {
    sid = "EcrReadForVerify"
    actions = [
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [aws_ecr_repository.podinfo.arn]
  }

  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid     = "ReadSignals"
    actions = [
      "cloudwatch:DescribeAlarms",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ApiDiscovery"
    actions   = ["apigateway:GET"]
    resources = ["arn:aws:apigateway:${var.region}::/apis"]
  }

  statement {
    sid       = "ActiveColorParam"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:${local.account_id}:parameter/${var.project}/*"]
  }

  statement {
    sid       = "EcrKms"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.main.arn]
  }
}

resource "aws_iam_role_policy" "ci_deploy" {
  name   = "ci-deploy"
  role   = aws_iam_role.ci_deploy.id
  policy = data.aws_iam_policy_document.ci_deploy.json
}
