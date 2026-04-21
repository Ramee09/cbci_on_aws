output "fluent_bit_role_arn" {
  description = "IRSA role ARN for Fluent Bit (CloudWatch Logs)"
  value       = aws_iam_role.fluent_bit.arn
}

output "velero_role_arn" {
  description = "IRSA role ARN for Velero"
  value       = aws_iam_role.velero.arn
}

output "velero_bucket" {
  description = "S3 bucket name for Velero backups"
  value       = aws_s3_bucket.velero.bucket
}

output "aws_backup_role_arn" {
  description = "Service role ARN for AWS Backup"
  value       = aws_iam_role.aws_backup.arn
}

output "github_actions_role_arn" {
  description = "IAM role ARN assumed by GitHub Actions via OIDC"
  value       = aws_iam_role.github_actions.arn
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for ExternalDNS"
  value       = aws_iam_role.external_dns.arn
}

output "jenkins_admin_secret_arn" {
  description = "Secrets Manager ARN for CBCI admin password"
  value       = aws_secretsmanager_secret.jenkins_admin.arn
}
