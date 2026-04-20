terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "cbci-lab-tfstate-835090871306"
    key            = "10-network/terraform.tfstate"
    region         = "us-east-1"
    profile        = "cbci-lab"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "cbci-lab"
}

# Resolve the 3 AZs available in us-east-1 at plan time
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  cluster_name = "cbci-lab"
  azs          = slice(data.aws_availability_zones.available.names, 0, 3)

  # Carve /20 slices out of 10.0.0.0/16
  # Public:  10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
  # Private: 10.0.48.0/20, 10.0.64.0/20, 10.0.80.0/20
  public_subnets  = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  private_subnets = ["10.0.48.0/20", "10.0.64.0/20", "10.0.80.0/20"]

  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.19.0"

  name = local.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  # Single NAT gateway — lab cost optimisation (~$32/mo)
  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  enable_dns_hostnames = true
  enable_dns_support   = true

  # Public subnet tags — required by AWS Load Balancer Controller for internet-facing ALBs
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  # Private subnet tags — required by AWS LBC for internal ALBs + Karpenter node discovery
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"     = "1"
    "karpenter.sh/discovery"              = local.cluster_name
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }

  tags = local.common_tags
}
