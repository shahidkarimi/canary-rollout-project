# Rollback signals for the Lambda target.
#
# Thresholds (defended in README): podinfo at demo traffic serves single-digit
# RPS with a ~0% baseline error rate and ~ms handler latency, so during a
# canary window *any* function error is a real signal (threshold 1, 1-minute
# period). The 5-minute canary hold spans >= 5 evaluation periods, giving the
# alarm multiple chances to fire before 100% shift.

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-lambda-errors"
  alarm_description   = "Any podinfo function error during/after canary"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.podinfo.function_name
    Resource     = "${aws_lambda_function.podinfo.function_name}:live"
  }

  alarm_actions = [local.global.alarms_topic_arn]
  ok_actions    = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  alarm_name          = "${local.name}-lambda-throttles"
  alarm_description   = "Podinfo invocations throttled"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.podinfo.function_name
  }

  alarm_actions = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration_p99" {
  alarm_name          = "${local.name}-lambda-duration-p99"
  alarm_description   = "p99 duration above 3s for 2 consecutive minutes (baseline is ~ms; 3s leaves headroom for cold starts)"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 2
  threshold           = 3000
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.podinfo.function_name
  }

  alarm_actions = [local.global.alarms_topic_arn]
}

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${local.name}-apigw-5xx"
  alarm_description   = "API Gateway 5xx >= 3/min (catches integration failures the function metric misses)"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.http.id
  }

  alarm_actions = [local.global.alarms_topic_arn]
}
