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
    key          = "60-platform/terraform.tfstate"
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
# Remote state
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

data "terraform_remote_state" "storage" {
  backend = "s3"
  config = {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "30-storage/terraform.tfstate"
    region       = "us-east-1"
    profile      = "cbci-lab"
    use_lockfile = true
  }
}

locals {
  cluster_name       = "cbci-lab"
  account_id         = "835090871306"
  region             = "us-east-1"
  hosted_zone_id     = "Z0799612KTOUP3I7DFHC"
  domain             = "myhomettbros.com"
  oidc_provider_arn  = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider_url  = regex("oidc-provider/(.*)", data.terraform_remote_state.eks.outputs.oidc_provider_arn)[0]

  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC provider
#
# Import existing provider:
#   terraform import aws_iam_openid_connect_provider.github \
#     arn:aws:iam::835090871306:oidc-provider/token.actions.githubusercontent.com
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# IAM role: Fluent Bit → CloudWatch Logs   (Phase 11)
#
# Import: terraform import aws_iam_role.fluent_bit cbci-lab-fluent-bit
# ---------------------------------------------------------------------------
resource "aws_iam_role" "fluent_bit" {
  name = "cbci-lab-fluent-bit"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:monitoring:fluent-bit"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "fluent_bit_cloudwatch" {
  name = "fluent-bit-cloudwatch"
  role = aws_iam_role.fluent_bit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
        "logs:DescribeLogGroups",
      ]
      Resource = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/eks/cbci-lab*"
    }]
  })
}

# ---------------------------------------------------------------------------
# IAM role: External Secrets Operator → Secrets Manager   (Phase 12b)
#
# Import: terraform import aws_iam_role.eso cbci-lab-eso
# ---------------------------------------------------------------------------
resource "aws_iam_role" "eso" {
  name = "cbci-lab-eso"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:external-secrets:external-secrets"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "eso_secrets_manager" {
  name = "eso-secrets-manager"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds",
      ]
      Resource = "arn:aws:secretsmanager:${local.region}:${local.account_id}:secret:cbci-lab/*"
    }]
  })
}

# ---------------------------------------------------------------------------
# S3 bucket: Velero backup storage   (Phase 13)
#
# Import: terraform import aws_s3_bucket.velero cbci-lab-velero-835090871306
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "velero" {
  bucket = "cbci-lab-velero-${local.account_id}"
  tags   = local.common_tags
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IAM role: Velero → S3 + EC2 snapshots   (Phase 13)
#
# Import: terraform import aws_iam_role.velero cbci-lab-velero
# ---------------------------------------------------------------------------
resource "aws_iam_role" "velero" {
  name = "cbci-lab-velero"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:velero:velero"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "velero_s3" {
  name = "velero-s3"
  role = aws_iam_role.velero.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateSnapshot",
          "ec2:DeleteSnapshot",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.velero.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.velero.arn
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# IAM role: AWS Backup service role   (Phase 13)
#
# Import: terraform import aws_iam_role.aws_backup cbci-lab-aws-backup
# ---------------------------------------------------------------------------
resource "aws_iam_role" "aws_backup" {
  name = "cbci-lab-aws-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "aws_backup_backup" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "aws_backup_restore" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# ---------------------------------------------------------------------------
# AWS Backup: EFS daily snapshots   (Phase 13)
#
# Import vault: terraform import aws_backup_vault.efs cbci-lab-efs-backup-vault
# Plan/selection IDs: look up with `aws backup list-backup-plans --profile cbci-lab`
# ---------------------------------------------------------------------------
resource "aws_backup_vault" "efs" {
  name = "cbci-lab-efs-backup-vault"
  tags = local.common_tags
}

resource "aws_backup_plan" "efs" {
  name = "cbci-lab-efs-backup-plan"

  rule {
    rule_name         = "daily-7day-retention"
    target_vault_name = aws_backup_vault.efs.name
    schedule          = "cron(0 3 * * ? *)"

    lifecycle {
      delete_after = 7
    }
  }

  tags = local.common_tags
}

resource "aws_backup_selection" "efs" {
  iam_role_arn = aws_iam_role.aws_backup.arn
  name         = "cbci-lab-efs"
  plan_id      = aws_backup_plan.efs.id
  resources    = [data.terraform_remote_state.storage.outputs.efs_filesystem_arn]
}

# ---------------------------------------------------------------------------
# IAM role: GitHub Actions → EKS   (Phase 14)
#
# Import: terraform import aws_iam_role.github_actions cbci-lab-github-actions
# ---------------------------------------------------------------------------
resource "aws_iam_role" "github_actions" {
  name = "cbci-lab-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:Ramee09/cbci_on_aws:ref:refs/heads/main"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "github_actions_eks" {
  name = "github-actions-eks"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = "arn:aws:eks:${local.region}:${local.account_id}:cluster/${local.cluster_name}"
    }]
  })
}

# ---------------------------------------------------------------------------
# Secrets Manager: secret names only — values are set via CLI, never via TF
#
# Import jenkins: terraform import aws_secretsmanager_secret.jenkins_admin \
#   $(aws secretsmanager describe-secret --secret-id cbci-lab/jenkins-admin-password \
#       --query ARN --output text --profile cbci-lab)
# Import grafana:  terraform import aws_secretsmanager_secret.grafana_admin \
#   $(aws secretsmanager describe-secret --secret-id cbci-lab/grafana-admin-password \
#       --query ARN --output text --profile cbci-lab)
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "jenkins_admin" {
  name        = "cbci-lab/jenkins-admin-password"
  description = "CBCI Operations Center admin password"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [tags_all]
  }
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name        = "cbci-lab/grafana-admin-password"
  description = "Grafana admin credentials (keys: username, password)"
  tags        = local.common_tags

  lifecycle {
    ignore_changes = [tags_all]
  }
}

# ---------------------------------------------------------------------------
# IAM role: ExternalDNS → Route 53   (closes gap from Phase 6)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "external_dns" {
  name = "cbci-lab-external-dns"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider_url}:sub" = "system:serviceaccount:kube-system:external-dns"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "external_dns_route53" {
  name = "external-dns-route53"
  role = aws_iam_role.external_dns.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets"]
        Resource = ["arn:aws:route53:::hostedzone/${local.hosted_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Helm: ExternalDNS   (installs into kube-system, manages myhomettbros.com)
# After install, manually delete any existing Route 53 A records for
# cjoc/devflow/test1 — ExternalDNS will recreate them from Ingress annotations.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# EKS Access Entry — maps cbci-lab-github-actions IAM role to k8s username
# "github-actions", which the Role in k8s/rbac-github-actions.yaml grants
# permission to update the oc-casc-bundle ConfigMap.
#
# This replaces the older aws-auth ConfigMap approach (eksctl iamidentitymapping).
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "github_actions" {
  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.github_actions.arn
  type          = "STANDARD"
  user_name     = "github-actions"
  tags          = local.common_tags
}

resource "helm_release" "external_dns" {
  namespace  = "kube-system"
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.16.1"
  wait       = true
  timeout    = 180

  values = [yamlencode({
    provider = { name = "aws" }
    aws = {
      region   = local.region
      zoneType = "public"
    }
    txtOwnerId    = local.cluster_name
    domainFilters = [local.domain]
    policy        = "sync"

    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns.arn
      }
    }

    tolerations = [{
      key      = "CriticalAddonsOnly"
      operator = "Exists"
    }]

    resources = {
      requests = { cpu = "50m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }

    logLevel = "info"
    interval = "1m"
  })]

  depends_on = [aws_iam_role.external_dns]
}
