output "vpc_id" {
  description = "VPC ID — consumed by 20-eks and 30-storage"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs (EKS nodes, EFS, controllers)"
  value       = module.vpc.private_subnets
}

output "nat_public_ips" {
  description = "Elastic IP of the single NAT gateway"
  value       = module.vpc.nat_public_ips
}

output "azs" {
  description = "Availability zones used"
  value       = module.vpc.azs
}
