variable "db_backup_retention_days" {
  description = "Number of days to retain Aurora automated backups."
  type        = number
  default     = 7
}

resource "aws_db_subnet_group" "db" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_rds_cluster" "db" {
  cluster_identifier              = "${local.name}-aurora"
  engine                          = "aurora-postgresql"
  database_name                   = "exams"
  master_username                 = "examadmin"
  manage_master_user_password     = true # password lives in Secrets Manager, never in code or state
  master_user_secret_kms_key_id   = aws_kms_key.main.arn
  storage_encrypted               = true
  kms_key_id                      = aws_kms_key.main.arn
  db_subnet_group_name            = aws_db_subnet_group.db.name
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
  count                = 2
  identifier           = "${local.name}-aurora-${count.index}"
  cluster_identifier   = aws_rds_cluster.db.id
  engine               = aws_rds_cluster.db.engine
  instance_class       = "db.serverless"
  availability_zone    = local.azs[count.index]
  promotion_tier       = 0
  db_subnet_group_name = aws_db_subnet_group.db.name
}

resource "aws_iam_role" "proxy" {
  name = "${local.name}-rds-proxy"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "proxy" {
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_rds_cluster.db.master_user_secret[0].secret_arn },
      { Effect = "Allow", Action = "kms:Decrypt", Resource = aws_kms_key.main.arn }
    ]
  })
}

# RDS Proxy pools connections so a Lambda burst at exam start cannot exhaust Postgres,
# and it re-routes to the new writer after a failover.
resource "aws_db_proxy" "db" {
  name                   = "${local.name}-proxy"
  engine_family          = "POSTGRESQL"
  require_tls            = true
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = aws_subnet.data[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  idle_client_timeout    = 1800
  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_rds_cluster.db.master_user_secret[0].secret_arn
  }
  depends_on = [aws_iam_role_policy.proxy]
}
resource "aws_db_proxy_default_target_group" "db" {
  db_proxy_name = aws_db_proxy.db.name
  connection_pool_config {
    max_connections_percent      = 90
    max_idle_connections_percent = 50
  }
}
resource "aws_db_proxy_target" "db" {
  db_proxy_name         = aws_db_proxy.db.name
  target_group_name     = aws_db_proxy_default_target_group.db.name
  db_cluster_identifier = aws_rds_cluster.db.id
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
  resources    = [aws_rds_cluster.db.arn]
}
