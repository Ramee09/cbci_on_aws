output "karpenter_node_role_name" {
  description = "IAM role name for Karpenter-provisioned nodes — referenced in EC2NodeClass"
  value       = module.karpenter.node_iam_role_name
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes"
  value       = module.karpenter.node_iam_role_arn
}

output "karpenter_controller_role_arn" {
  description = "IRSA role ARN for the Karpenter controller service account"
  value       = module.karpenter.iam_role_arn
}

output "karpenter_interruption_queue" {
  description = "SQS queue name for Karpenter spot interruption handling"
  value       = module.karpenter.queue_name
}
