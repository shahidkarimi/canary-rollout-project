resource "aws_kms_key" "main" {
  description             = "${var.project}-rollout CMK (secrets, ECR)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "main" {
  name          = "alias/${var.project}-rollout"
  target_key_id = aws_kms_key.main.key_id
}

resource "aws_sns_topic" "alarms" {
  name = "${var.project}-rollout-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}
