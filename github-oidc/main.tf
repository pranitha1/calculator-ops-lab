terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Fetches GitHub's OIDC signing certificate so AWS can verify tokens GitHub
# issues are genuinely from GitHub, not forged. This uses a NEW provider
# (tls) purely to read a public cert - it doesn't create or manage anything.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# Registers GitHub Actions as a trusted identity source for this AWS account.
# One-time setup - every repo's workflows can potentially use it, access is
# actually restricted per-role below, not here.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS wants the INTERMEDIATE CA's thumbprint here, not the root's. The
  # certificate chain returned by this data source is ordered
  # [root, intermediate, leaf] - index [0] (root) was the original bug;
  # index [1] is the correct intermediate.
  thumbprint_list = [data.tls_certificate.github.certificates[1].sha1_fingerprint]
}

# The trust policy: WHO is allowed to assume this role, and under what
# conditions. This is the real security boundary.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # Confirms the token was actually issued for talking to AWS specifically
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE critical line: restricts this role to workflows running from OUR
    # specific repo only. Without this, the trust would be far too broad.
    # NOTE: GitHub appends immutable numeric IDs after the owner and repo
    # name (e.g. "pranitha1@47051317") to prevent trust hijacking via
    # account/repo renames - confirmed empirically by decoding a real
    # token, not from documentation. The @* wildcards account for this.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:pranitha1@*/calculator-ops-lab@*:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "github-actions-calculator-ops-lab"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Project   = "calculator-ops-lab"
    ManagedBy = "Terraform"
    Purpose   = "GitHub Actions OIDC federation"
  }
}

# What the role can DO once assumed. Scoped to the specific services our
# Terraform stacks actually touch (not full AdministratorAccess) - though
# honestly not fully least-privilege either (that would mean auditing every
# exact action across all 4 stacks). Real production would tighten this
# further; this is the practical middle ground for a learning environment.
resource "aws_iam_role_policy" "github_actions_permissions" {
  name = "terraform-stack-permissions"
  role = aws_iam_role.github_actions.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:*", "rds:*", "s3:*",
          "iam:Get*", "iam:List*", "iam:PassRole",
          "iam:CreateRole", "iam:DeleteRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:TagRole", "iam:CreateServiceLinkedRole",
          "cloudwatch:*", "logs:*", "sns:*", "ssm:*", "acm:*", "autoscaling:*",
          "elasticloadbalancing:*"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
