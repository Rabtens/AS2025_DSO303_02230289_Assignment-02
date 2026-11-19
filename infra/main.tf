terraform {
  required_version = ">= 1.10"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.80" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
  # Partial config: bucket/key/region are passed with -backend-config (see README and CI workflow).
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform" }
  }
}

# CloudFront WAF and ACM certificates must live in us-east-1.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags {
    tags = { Project = var.project, ManagedBy = "terraform" }
  }
}

variable "project" {
  type    = string
  default = "exam-platform"
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "ses_sender" {
  type        = string
  description = "Verified SES identity used as the From address"
}
variable "tutor_email" {
  type        = string
  description = "Address notified on new assignment uploads (verify it too while SES is in sandbox)"
}
variable "alarm_email" {
  type        = string
  description = "Address subscribed to the alarm SNS topic"
}
variable "db_min_acu" {
  type    = number
  default = 0.5
}
variable "db_max_acu" {
  type    = number
  default = 8
}
variable "domain_name" {
  type        = string
  default     = ""
  description = "Optional custom domain (needs hosted_zone_id). Empty = use the CloudFront domain."
}
variable "hosted_zone_id" {
  type    = string
  default = ""
}

data "aws_caller_identity" "me" {}
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs           = slice(data.aws_availability_zones.available.names, 0, 2)
  name          = var.project
  account_id    = data.aws_caller_identity.me.account_id
  custom_domain = var.domain_name != "" && var.hosted_zone_id != ""
}

resource "aws_kms_key" "main" {
  description             = "${local.name} data key (S3 uploads, Aurora, secrets, backups)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}
resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}
