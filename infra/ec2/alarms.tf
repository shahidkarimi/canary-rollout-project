# Rollback signals for the EC2/ALB target.
#
# Thresholds (defended in README): demo traffic is low and podinfo's healthy
# baseline is 0 errors / ~ms latency, so 3+ target 5xx in a minute or a p99
# above 1s for 2 consecutive minutes is unambiguous regression signal during
# the 2-minute canary hold (1-minute periods give the alarm 2 chances to fire
# before full shift).

resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${local.name}-alb-target-5xx"
  alarm_description   = "Backend 5xx >= 3/min behind the ALB"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [local.global.alarms_topic_arn]
  ok_actions    = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_target_response_time" {
  alarm_name          = "${local.name}-alb-target-rt-p99"
  alarm_description   = "Target p99 response time > 1s for 2 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "host_cpu" {
  alarm_name          = "${local.name}-host-cpu"
  alarm_description   = "ASG average CPU > 80% for 5 minutes (operational, not a rollback gate)"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.podinfo.name
  }

  alarm_actions = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "host_memory" {
  alarm_name          = "${local.name}-host-memory"
  alarm_description   = "ASG average memory > 85% for 5 minutes (operational, not a rollback gate)"
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.podinfo.name
  }

  alarm_actions = [local.global.alarms_topic_arn]
}
