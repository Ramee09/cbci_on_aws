terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }

  backend "s3" {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "50-ingress/terraform.tfstate"
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

provider "helm" {
  kubernetes {
    host                   = data.terraform_remote_state.eks.outputs.cluster_endpoint
    cluster_ca_certificate = base64decode(data.terraform_remote_state.eks.outputs.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", local.cluster_name, "--profile", "cbci-lab"]
    }
  }
}

# ---------------------------------------------------------------------------
# Remote state — EKS and network outputs
# ---------------------------------------------------------------------------
data "terraform_remote_state" "eks" {
  backend = "s3"
  config = {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "20-eks/terraform.tfstate"
    region       = "us-east-1"
    profile      = "cbci-lab"
    use_lockfile = true
  }
}

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
  cluster_name = "cbci-lab"
  vpc_id       = data.terraform_remote_state.network.outputs.vpc_id

  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# IRSA role — AWS Load Balancer Controller
# ---------------------------------------------------------------------------
module "aws_lbc_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.52.2"

  role_name                              = "cbci-lab-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = data.terraform_remote_state.eks.outputs.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Helm: AWS Load Balancer Controller
# ---------------------------------------------------------------------------
resource "helm_release" "aws_lbc" {
  namespace  = "kube-system"
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.2.1"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    clusterName  = local.cluster_name
    region       = "us-east-1"
    vpcId        = local.vpc_id
    replicaCount = 1

    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.aws_lbc_irsa_role.iam_role_arn
      }
    }

    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
    }]

    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { cpu = "500m", memory = "512Mi" }
    }
  })]

  depends_on = [module.aws_lbc_irsa_role]
}
