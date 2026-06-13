output "ecr_repository_url" {
  value = aws_ecr_repository.podinfo.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.podinfo.arn
}

output "ci_build_role_arn" {
  value = aws_iam_role.ci_build.arn
}

output "ci_deploy_role_arn" {
  value = aws_iam_role.ci_deploy.arn
}

output "revisions_bucket" {
  value = aws_s3_bucket.revisions.bucket
}

output "alarms_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "secret_arn" {
  value = aws_secretsmanager_secret.token.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.token.name
}
