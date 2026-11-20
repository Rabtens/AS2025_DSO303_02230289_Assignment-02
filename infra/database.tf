variable "db_backup_retention_days" {
  description = "Number of days to retain Aurora automated backups."
  type        = number
  default     = 7
}

resource "aws_db_subnet_group" "db" {
  count      = var.db_express ? 0 : 1
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_rds_cluster" "db" {
  count                           = var.db_express ? 0 : 1
  cluster_identifier              = "${local.name}-aurora"
  engine                          = "aurora-postgresql"
  database_name                   = "exams"
  master_username                 = "examadmin"
  manage_master_user_password     = true # password lives in Secrets Manager, never in code or state
  master_user_secret_kms_key_id   = aws_kms_key.main.arn
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.main.arn
  db_subnet_group_name            = aws_db_subnet_group.db[0].name
  vpc_security_group_ids          = [aws_security_group.db.id]
  backup_retention_period         = var.db_backup_retention_days
  skip_final_snapshot             = true # lab setting; use a final snapshot + deletion_protection in production
  apply_immediately               = true
  enabled_cloudwatch_logs_exports = ["postgresql"]

  serverlessv2_scaling_configuration {
    min_capacity = var.db_min_acu
    max_capacity = var.db_max_acu
  }
}

# Writer in AZ-a, reader (failover target, promotion tier 0) in AZ-b.
resource "aws_rds_cluster_instance" "db" {
  count                = var.db_express ? 0 : 2
  identifier           = "${local.name}-aurora-${count.index}"
  cluster_identifier   = aws_rds_cluster.db[0].id
  engine               = aws_rds_cluster.db[0].engine
  instance_class       = "db.serverless"
  availability_zone    = local.azs[count.index]
  promotion_tier       = 0
  db_subnet_group_name = aws_db_subnet_group.db[0].name
}

resource "aws_iam_role" "proxy" {
  count = var.db_express ? 0 : 1
  name  = "${local.name}-rds-proxy"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "proxy" {
  count = var.db_express ? 0 : 1
  role  = aws_iam_role.proxy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_rds_cluster.db[0].master_user_secret[0].secret_arn },
      { Effect = "Allow", Action = "kms:Decrypt", Resource = aws_kms_key.main.arn }
    ]
  })
}

# RDS Proxy pools connections so a Lambda burst at exam start cannot exhaust Postgres,
# and it re-routes to the new writer after a failover.
resource "aws_db_proxy" "db" {
  count                  = var.db_express ? 0 : 1
  name                   = "${local.name}-proxy"
  engine_family          = "POSTGRESQL"
  require_tls            = true
  role_arn               = aws_iam_role.proxy[0].arn
  vpc_subnet_ids         = aws_subnet.data[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  idle_client_timeout    = 1800
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_rds_cluster.db[0].master_user_secret[0].secret_arn
  }
  depends_on = [aws_iam_role_policy.proxy]
}
resource "aws_db_proxy_default_target_group" "db" {
  count         = var.db_express ? 0 : 1
  db_proxy_name = aws_db_proxy.db[0].name
  connection_pool_config {
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}
resource "aws_db_proxy_target" "db" {
  count                 = var.db_express ? 0 : 1
  db_proxy_name         = aws_db_proxy.db[0].name
  target_group_name     = aws_db_proxy_default_target_group.db[0].name
  db_cluster_identifier = aws_rds_cluster.db[0].id
  depends_on            = [aws_rds_cluster_instance.db]
}

# ---- 5-year record retention for the database (monthly recovery points kept 1825 days) ----
resource "aws_backup_vault" "main" {
  name        = "${local.name}-vault"
  kms_key_arn = aws_kms_key.main.arn
}
resource "aws_backup_plan" "main" {
  name = "${local.name}-plan"
  rule {
    rule_name         = "daily-35d"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 * * ? *)"
    lifecycle { delete_after = 35 }
  }
  rule {
    rule_name         = "monthly-5y"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 4 1 * ? *)"
    lifecycle { delete_after = 1825 }
  }
}
resource "aws_iam_role" "backup" {
  name = "${local.name}-backup"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "backup.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}
resource "aws_backup_selection" "db" {
  name         = "aurora"
  plan_id      = aws_backup_plan.main.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [local.db_cluster_arn]
}


variable "db_express" {
  description = "Use Aurora Express and IAM database authentication for an AWS Free Plan deployment."
  type        = bool
  default     = false
}

resource "aws_cloudformation_stack" "aurora_express" {
  count = var.db_express ? 1 : 0
  name  = "${local.name}-aurora-express"

  template_body = jsonencode({
    Resources = {
      Cluster = {
        Type = "AWS::RDS::DBCluster"
        Properties = {
          Engine                   = "aurora-postgresql"
          DBClusterIdentifier      = "${local.name}-aurora-express"
          WithExpressConfiguration = true
        }
      }
    }
    Outputs = {
      Identifier = { Value = { Ref = "Cluster" } }
      Arn        = { Value = { "Fn::GetAtt" = ["Cluster", "DBClusterArn"] } }
      Endpoint   = { Value = { "Fn::GetAtt" = ["Cluster", "Endpoint.Address"] } }
      ResourceId = { Value = { "Fn::GetAtt" = ["Cluster", "DBClusterResourceId"] } }
    }
  })
}

locals {
  express_outputs = var.db_express ? aws_cloudformation_stack.aurora_express[0].outputs : null
  db_cluster_id   = var.db_express ? local.express_outputs.Identifier : aws_rds_cluster.db[0].cluster_identifier
  db_cluster_arn  = var.db_express ? local.express_outputs.Arn : aws_rds_cluster.db[0].arn
}

moved {
  from = aws_db_subnet_group.db
  to   = aws_db_subnet_group.db[0]
}

moved {
  from = aws_rds_cluster.db
  to   = aws_rds_cluster.db[0]
}

moved {
  from = aws_iam_role.proxy
  to   = aws_iam_role.proxy[0]
}

moved {
  from = aws_iam_role_policy.proxy
  to   = aws_iam_role_policy.proxy[0]
}

moved {
  from = aws_db_proxy.db
  to   = aws_db_proxy.db[0]
}

moved {
  from = aws_db_proxy_default_target_group.db
  to   = aws_db_proxy_default_target_group.db[0]
}

moved {
  from = aws_db_proxy_target.db
  to   = aws_db_proxy_target.db[0]
}
