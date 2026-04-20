terraform {
  required_version = ">= 1.4.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "cbci-lab-tfstate-835090871306"
    key          = "30-storage/terraform.tfstate"
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

locals {
  cluster_name       = "cbci-lab"
  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
  node_sg_id         = data.terraform_remote_state.eks.outputs.node_security_group_id

  common_tags = {
    Project     = "cbci-lab"
    ManagedBy   = "terraform"
    Environment = "lab"
  }
}

# ---------------------------------------------------------------------------
# KMS key — EFS encryption at rest
# ---------------------------------------------------------------------------
resource "aws_kms_key" "efs" {
  description             = "cbci-lab EFS encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "cbci-lab-efs" })
}

resource "aws_kms_alias" "efs" {
  name          = "alias/cbci-lab-efs"
  target_key_id = aws_kms_key.efs.key_id
}

# ---------------------------------------------------------------------------
# Security group — NFS (2049) from EKS nodes only
# ---------------------------------------------------------------------------
resource "aws_security_group" "efs" {
  name        = "cbci-lab-efs"
  description = "Allow NFS from EKS nodes to EFS mount targets"
  vpc_id      = local.vpc_id

  ingress {
    description     = "NFS from EKS nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [local.node_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "cbci-lab-efs" })
}

# ---------------------------------------------------------------------------
# EFS filesystem
# ---------------------------------------------------------------------------
resource "aws_efs_file_system" "cbci" {
  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true
  kms_key_id       = aws_kms_key.efs.arn

  tags = merge(local.common_tags, { Name = "cbci-lab" })
}

# ---------------------------------------------------------------------------
# Mount targets — one per private subnet
# ---------------------------------------------------------------------------
resource "aws_efs_mount_target" "private" {
  for_each = toset(local.private_subnet_ids)

  file_system_id  = aws_efs_file_system.cbci.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

# ---------------------------------------------------------------------------
# Access Points — one per CBCI component, uid/gid 1000 = jenkins user
# ---------------------------------------------------------------------------
resource "aws_efs_access_point" "oc" {
  file_system_id = aws_efs_file_system.cbci.id

  root_directory {
    path = "/oc"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  posix_user {
    gid = 1000
    uid = 1000
  }

  tags = merge(local.common_tags, { Name = "cbci-lab-oc" })
}

resource "aws_efs_access_point" "devflow" {
  file_system_id = aws_efs_file_system.cbci.id

  root_directory {
    path = "/devflow"
    creation_info {
      owner_gid   = 1000
      owner_uid   = 1000
      permissions = "755"
    }
  }

  posix_user {
    gid = 1000
    uid = 1000
  }

  tags = merge(local.common_tags, { Name = "cbci-lab-devflow" })
}

# ---------------------------------------------------------------------------
# StorageClass — inject EFS filesystem ID then apply
# ---------------------------------------------------------------------------
resource "null_resource" "efs_storageclass" {
  triggers = {
    fs_id = aws_efs_file_system.cbci.id
  }

  provisioner "local-exec" {
    environment = { AWS_PROFILE = "cbci-lab" }
    command     = <<-EOT
      sed 's|EFS_FS_ID|${aws_efs_file_system.cbci.id}|g' \
        ${path.module}/../../k8s/storageclass-efs.yaml | kubectl apply -f -
    EOT
  }

  depends_on = [aws_efs_mount_target.private]
}
