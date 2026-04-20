output "lbc_iam_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller (used in Phase 7 Helm values)"
  value       = module.aws_lbc_irsa_role.iam_role_arn
}
