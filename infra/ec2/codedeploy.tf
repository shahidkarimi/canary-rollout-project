data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${local.name}-ec2-codedeploy"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_trust.json
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

resource "aws_codedeploy_app" "ec2" {
  name             = "${local.name}-ec2"
  compute_platform = "Server"
}

# In-place revision rollout to both hosts at once: traffic safety does not
# come from instance-by-instance rollout but from the ALB weighted canary the
# ValidateService hook performs (blue keeps serving until green is proven).
resource "aws_codedeploy_deployment_group" "ec2" {
  app_name               = aws_codedeploy_app.ec2.name
  deployment_group_name  = "${local.name}-ec2-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.AllAtOnce"

  autoscaling_groups = [aws_autoscaling_group.podinfo.name]

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  alarm_configuration {
    enabled = true
    alarms = [
      aws_cloudwatch_metric_alarm.alb_target_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.alb_target_response_time.alarm_name,
    ]
  }
}
