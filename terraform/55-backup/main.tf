terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "55-backup/terraform.tfstate"
    region       = "us-east-1"
    profile      = "cbci-lab"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "cbci-lab"
  alias   = "primary"
}

# Cross-region provider for DR copy vault in us-west-2
provider "aws" {
  region  = "us-west-2"
  profile = "cbci-lab"
  alias   = "dr"
}

locals {
  account_id        = "835090871306"
  cluster_name      = "cbci-lab"
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_issuer = trimprefix(
    regex("oidc-provider/(.+)", local.oidc_provider_arn)[0],
    ""
  )
  common_tags = {
    Project     = "cbci-platform"
    ManagedBy   = "terraform"
    Component   = "backup"
  }
}

# ---------------------------------------------------------------------------
# Read remote state to get EFS filesystem ID and EKS OIDC issuer
# ---------------------------------------------------------------------------
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

# ============================================================
# 1. S3 BUCKET — Velero backup storage
# ============================================================
resource "aws_s3_bucket" "velero" {
  provider      = aws.primary
  bucket        = "cbci-velero-backups-${local.account_id}"
  force_destroy = false

  tags = merge(local.common_tags, { Name = "cbci-velero-backups" })
}

resource "aws_s3_bucket_versioning" "velero" {
  provider = aws.primary
  bucket   = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  provider = aws.primary
  bucket   = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  provider                = aws.primary
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================================
# 2. IAM ROLE — Velero IRSA (IAM Roles for Service Accounts)
# ============================================================
data "aws_iam_policy_document" "velero_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:velero:velero"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "velero" {
  provider           = aws.primary
  name               = "cbci-velero"
  assume_role_policy = data.aws_iam_policy_document.velero_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "velero_policy" {
  # S3 object access for backup storage
  statement {
    sid    = "VeleroS3"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:ListBucket", "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts",
    ]
    resources = [
      aws_s3_bucket.velero.arn,
      "${aws_s3_bucket.velero.arn}/*",
    ]
  }
  # EC2 volume snapshot access (for PVC snapshots — optional but recommended)
  statement {
    sid    = "VeleroEC2Snapshots"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes", "ec2:DescribeSnapshots",
      "ec2:CreateSnapshot", "ec2:DeleteSnapshot",
      "ec2:CreateTags", "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "velero" {
  provider = aws.primary
  name     = "cbci-velero-policy"
  role     = aws_iam_role.velero.name
  policy   = data.aws_iam_policy_document.velero_policy.json
}

# ============================================================
# 3. AWS BACKUP VAULT — primary (us-east-1)
# ============================================================
resource "aws_backup_vault" "primary" {
  provider = aws.primary
  name     = "cbci-efs-backup-vault"
  tags     = merge(local.common_tags, { Name = "cbci-efs-backup-vault" })
}

# ============================================================
# 4. AWS BACKUP VAULT — DR copy (us-west-2)
# ============================================================
resource "aws_backup_vault" "dr" {
  provider = aws.dr
  name     = "cbci-efs-backup-vault-dr"
  tags     = merge(local.common_tags, { Name = "cbci-efs-backup-vault-dr", Region = "us-west-2" })
}

# ============================================================
# 5. AWS BACKUP PLAN — daily EFS snapshots + cross-region copy
# ============================================================
resource "aws_backup_plan" "efs_daily" {
  provider = aws.primary
  name     = "cbci-efs-daily"

  rule {
    rule_name         = "daily-warm-30d"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 1 * * ? *)" # 01:00 UTC daily

    lifecycle {
      cold_storage_after = 30  # move to cold after 30 days
      delete_after       = 120 # delete after 120 days total
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.dr.arn
      lifecycle {
        delete_after = 7 # keep DR copy 7 days
      }
    }
  }

  tags = local.common_tags
}

# ============================================================
# 6. IAM ROLE — AWS Backup service role
# ============================================================
resource "aws_iam_role" "aws_backup" {
  provider = aws.primary
  name     = "cbci-aws-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
    }]
  })
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "aws_backup_efs" {
  provider   = aws.primary
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "aws_backup_restore" {
  provider   = aws.primary
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForRestores"
}

# ============================================================
# 7. AWS BACKUP SELECTION — target the CBCI EFS filesystem
# ============================================================
resource "aws_backup_selection" "efs" {
  provider     = aws.primary
  name         = "cbci-efs"
  plan_id      = aws_backup_plan.efs_daily.id
  iam_role_arn = aws_iam_role.aws_backup.arn

  resources = [
    data.terraform_remote_state.storage.outputs.efs_filesystem_arn,
  ]
}

# ============================================================
# OUTPUTS
# ============================================================
output "velero_s3_bucket" {
  description = "S3 bucket name for Velero backups"
  value       = aws_s3_bucket.velero.bucket
}

output "velero_iam_role_arn" {
  description = "IAM role ARN for Velero IRSA annotation"
  value       = aws_iam_role.velero.arn
}

output "backup_vault_arn" {
  description = "Primary AWS Backup vault ARN"
  value       = aws_backup_vault.primary.arn
}

output "backup_plan_id" {
  description = "AWS Backup plan ID"
  value       = aws_backup_plan.efs_daily.id
}
