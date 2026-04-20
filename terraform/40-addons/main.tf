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
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "40-addons/terraform.tfstate"
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
  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# Karpenter — IAM roles, SQS interruption queue, EventBridge rules
# ---------------------------------------------------------------------------
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "20.36.0"

  cluster_name           = local.cluster_name
  namespace              = "kube-system"
  enable_irsa            = true
  irsa_oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  # Trust the kube-system:karpenter SA — must match the Helm chart's namespace
  irsa_namespace_service_accounts = ["kube-system:karpenter"]

  # SSM lets you shell into Karpenter nodes for debugging without a bastion
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.common_tags
}

# Tag node SG so EC2NodeClass can discover it via karpenter.sh/discovery
resource "aws_ec2_tag" "node_sg_karpenter" {
  resource_id = data.terraform_remote_state.eks.outputs.node_security_group_id
  key         = "karpenter.sh/discovery"
  value       = local.cluster_name
}

# ---------------------------------------------------------------------------
# Helm: Karpenter controller
# ---------------------------------------------------------------------------
resource "helm_release" "karpenter" {
  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.4.0"
  wait             = true
  wait_for_jobs    = true
  timeout          = 300

  values = [yamlencode({
    settings = {
      clusterName       = local.cluster_name
      interruptionQueue = module.karpenter.queue_name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
      }
    }
    # Run on system nodes (tainted CriticalAddonsOnly)
    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
    }]
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "1",    memory = "1Gi" }
      }
    }
  })]

  depends_on = [module.karpenter]
}

# ---------------------------------------------------------------------------
# EC2NodeClass + NodePools — applied after CRDs are registered
# ---------------------------------------------------------------------------
resource "null_resource" "karpenter_manifests" {
  triggers = {
    karpenter_version = helm_release.karpenter.version
    node_role         = module.karpenter.node_iam_role_name
  }

  provisioner "local-exec" {
    environment = { AWS_PROFILE = "cbci-lab" }
    command     = <<-EOT
      kubectl wait --for=condition=Established \
        crd/ec2nodeclasses.karpenter.k8s.aws \
        crd/nodepools.karpenter.sh \
        --timeout=120s
      # Inject the actual role name (has a generated suffix) into EC2NodeClass
      sed 's|KARPENTER_NODE_ROLE|${module.karpenter.node_iam_role_name}|g' \
        ${path.module}/../../k8s/karpenter/ec2nodeclass.yaml | kubectl apply -f -
      kubectl apply -f ${path.module}/../../k8s/karpenter/nodepool-controllers.yaml
      kubectl apply -f ${path.module}/../../k8s/karpenter/nodepool-agents.yaml
    EOT
  }

  depends_on = [helm_release.karpenter]
}
