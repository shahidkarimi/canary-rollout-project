output "alb_dns_name" {
  value = aws_lb.main.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.main.arn_suffix
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "blue_target_group_arn" {
  value = aws_lb_target_group.blue.arn
}

output "green_target_group_arn" {
  value = aws_lb_target_group.green.arn
}

output "blue_tg_arn_suffix" {
  value = aws_lb_target_group.blue.arn_suffix
}

output "green_tg_arn_suffix" {
  value = aws_lb_target_group.green.arn_suffix
}

output "asg_name" {
  value = aws_autoscaling_group.podinfo.name
}

output "codedeploy_app" {
  value = aws_codedeploy_app.ec2.name
}

output "codedeploy_group" {
  value = aws_codedeploy_deployment_group.ec2.deployment_group_name
}

output "docker_log_group" {
  value = aws_cloudwatch_log_group.docker.name
}
