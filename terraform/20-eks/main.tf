terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }

  backend "s3" {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "20-eks/terraform.tfstate"
    region       = "us-east-1"
    profile      = "cbci-lab"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "cbci-lab"
}

# Kubernetes provider wired to the cluster — used by the EKS module for add-on bootstrapping
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--profile", "cbci-lab"]
  }
}

# ---------------------------------------------------------------------------
# Remote state — read VPC/subnet IDs from Phase 2 without hardcoding them
# ---------------------------------------------------------------------------
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "10-network/terraform.tfstate"
    region       = "us-east-1"
    profile      = "cbci-lab"
    use_lockfile = true
  }
}

locals {
  cluster_name    = "cbci-lab"
  cluster_version = "1.31"

  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids

  # Restrict API server public endpoint to the owner's home IP only
  api_allowed_cidrs = var.api_allowed_cidrs

  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# EKS cluster
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.36.0"

  cluster_name    = local.cluster_name
  cluster_version = local.cluster_version

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnet_ids

  # API endpoint: public (for kubectl from laptop) but locked to owner IP
  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = local.api_allowed_cidrs
  cluster_endpoint_private_access      = true

  # OIDC provider — required for IRSA on all add-ons and Karpenter
  enable_irsa = true

  # Grant the IAM user that runs Terraform cluster-admin access via EKS Access Entry API
  enable_cluster_creator_admin_permissions = true

  # Cluster-level logging (cheap; audit log is most useful)
  cluster_enabled_log_types = ["audit", "api", "authenticator"]

  # EKS managed add-ons — pinned versions resolved from us-east-1 at time of build
  cluster_addons = {
    vpc-cni = {
      addon_version               = "v1.21.1-eksbuild.7"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns = {
      addon_version               = "v1.11.4-eksbuild.33"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      addon_version               = "v1.31.14-eksbuild.9"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      addon_version               = "v1.58.0-eksbuild.1"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
    }
    aws-efs-csi-driver = {
      addon_version               = "v3.0.0-eksbuild.1"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      service_account_role_arn    = module.efs_csi_irsa.iam_role_arn
    }
    metrics-server = {
      addon_version               = "v0.8.1-eksbuild.6"
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # System managed node group — stable nodes for cluster-critical pods
  eks_managed_node_groups = {
    system = {
      name           = "system"
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      subnet_ids = local.private_subnet_ids

      labels = {
        role = "system"
      }

      # Prevent workload pods from landing on system nodes
      taints = [
        {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      ]

      update_config = {
        max_unavailable_percentage = 50
      }
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# IRSA roles for EBS and EFS CSI drivers
# ---------------------------------------------------------------------------
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

  role_name             = "${local.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}

module "efs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

  role_name             = "${local.cluster_name}-efs-csi"
  attach_efs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:efs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}
