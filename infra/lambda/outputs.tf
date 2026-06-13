output "api_endpoint" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

output "api_id" {
  value = aws_apigatewayv2_api.http.id
}

output "function_name" {
  value = aws_lambda_function.podinfo.function_name
}

output "alias_name" {
  value = aws_lambda_alias.live.name
}

output "codedeploy_app" {
  value = aws_codedeploy_app.lambda.name
}

output "codedeploy_group" {
  value = aws_codedeploy_deployment_group.lambda.deployment_group_name
}

output "log_group_function" {
  value = aws_cloudwatch_log_group.fn.name
}

output "log_group_apigw" {
  value = aws_cloudwatch_log_group.apigw.name
}
