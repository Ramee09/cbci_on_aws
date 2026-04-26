terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "cbci-lab-tfstate-835090871306"
    key            = "45-github-oidc/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "cbci-lab-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "cbci-lab"
}

# GitHub Actions OIDC provider (one per AWS account, not per repo)
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint (stable, published by GitHub)
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# IAM role assumed by GitHub Actions workflows in this repo
resource "aws_iam_role" "github_actions_cbci" {
  name = "cbci-lab-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # Restrict to pushes on the main branch of this repo only
            "token.actions.githubusercontent.com:sub" = "repo:Ramee09/cbci_on_aws:ref:refs/heads/main"
          }
        }
      }
    ]
  })
}

# Allow the role to call eks:DescribeCluster (needed for update-kubeconfig)
resource "aws_iam_role_policy" "github_actions_eks" {
  name = "eks-describe"
  role = aws_iam_role.github_actions_cbci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:us-east-1:835090871306:cluster/cbci-lab"
      }
    ]
  })
}

output "role_arn" {
  description = "ARN to set as GHA secret CBCI_GHA_ROLE_ARN"
  value       = aws_iam_role.github_actions_cbci.arn
}
