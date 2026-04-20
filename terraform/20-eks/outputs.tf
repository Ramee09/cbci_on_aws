output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = module.eks.cluster_version
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — used by all IRSA roles"
  value       = module.eks.oidc_provider_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA cert for kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "node_security_group_id" {
  description = "Security group ID shared by all EKS nodes — needed for EFS mount target SG rule in Phase 5"
  value       = module.eks.node_security_group_id
}
