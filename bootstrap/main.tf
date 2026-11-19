# One-off stack: Terraform state bucket + GitHub OIDC role used by the pipeline.
# Run once with local state:  cd bootstrap && terraform init && terraform apply -var github_repo=<owner>/<repo>
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
}

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "github_repo" {
  type        = string
  description = "owner/repo that is allowed to deploy"
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "me" {}

resource "aws_s3_bucket" "state" {
  bucket = "exam-platform-tfstate-${data.aws_caller_identity.me.account_id}"
}
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "deploy" {
  name = "exam-platform-github-deploy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Federated = aws_iam_openid_connect_provider.github.arn }, Action = "sts:AssumeRoleWithWebIdentity",
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*" }
      }
    }]
  })
}
# Terraform creates IAM roles, so the lab uses AdministratorAccess. Scope this down for production.
resource "aws_iam_role_policy_attachment" "deploy" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "state_bucket" { value = aws_s3_bucket.state.id }
output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
