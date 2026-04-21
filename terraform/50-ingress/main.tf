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

# ---------------------------------------------------------------------------
# Route 53 hosted zone — pre-existing, managed outside this repo
# ---------------------------------------------------------------------------
data "aws_route53_zone" "domain" {
  name         = "myhomettbros.com."
  private_zone = false
}

# ---------------------------------------------------------------------------
# ACM wildcard certificate — *.myhomettbros.com   (Phase 12a)
#
# Import: terraform import aws_acm_certificate.wildcard \
#   arn:aws:acm:us-east-1:835090871306:certificate/8d0bab7f-cd88-45de-911f-1574b1f3db60
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.myhomettbros.com"
  validation_method = "DNS"

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.domain.zone_id
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for record in aws_route53_record.acm_validation : record.fqdn]
}
