############ Frontend bucket (private, served only through CloudFront OAC) ############
resource "aws_s3_bucket" "frontend" {
  bucket        = "${local.name}-frontend-${local.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Principal = { Service = "cloudfront.amazonaws.com" }, Action = "s3:GetObject",
        Resource  = "${aws_s3_bucket.frontend.arn}/*",
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn } }
      },
      {
        Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"],
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/../frontend/index.html"
  etag         = filemd5("${path.module}/../frontend/index.html")
  content_type = "text/html"
}
resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "config.json"
  content_type = "application/json"
  content      = jsonencode({ region = var.region, clientId = aws_cognito_user_pool_client.web.id })
}

############ Uploads bucket (assignment files, 5-year retention) ############
resource "aws_s3_bucket" "uploads" {
  bucket        = "${local.name}-uploads-${local.account_id}"
  force_destroy = true # lab only
}
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket                  = aws_s3_bucket.uploads.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}
resource "aws_s3_bucket_policy" "uploads_tls" {
  bucket = aws_s3_bucket.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.uploads.arn, "${aws_s3_bucket.uploads.arn}/*"],
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}
resource "aws_s3_bucket_cors_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  cors_rule {
    allowed_methods = ["POST"]
    allowed_origins = ["https://${local.custom_domain ? var.domain_name : aws_cloudfront_distribution.cdn.domain_name}"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}
# Lifecycle: hot 30 days -> Standard-IA -> Glacier Instant Retrieval at 180 days -> delete after 5 years + 5 days.
resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  rule {
    id     = "retention-5-years"
    status = "Enabled"
    filter {}
    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }
    transition {
      days          = 180
      storage_class = "GLACIER_IR"
    }
    expiration { days = 1830 }
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 2 }
  }
}
resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  queue {
    queue_arn     = aws_sqs_queue.notify.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
  }
  depends_on = [aws_sqs_queue_policy.notify]
}

############ Queues (async marking + email) ############
resource "aws_sqs_queue" "marking_dlq" {
  name                      = "${local.name}-marking-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "marking" {
  name                       = "${local.name}-marking"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 180
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.marking_dlq.arn, maxReceiveCount = 5 })
}
resource "aws_sqs_queue" "notify_dlq" {
  name                      = "${local.name}-notify-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "notify" {
  name                       = "${local.name}-notify"
  sqs_managed_sse_enabled    = true
  visibility_timeout_seconds = 180
  redrive_policy             = jsonencode({ deadLetterTargetArn = aws_sqs_queue.notify_dlq.arn, maxReceiveCount = 5 })
}
resource "aws_sqs_queue_policy" "notify" {
  queue_url = aws_sqs_queue.notify.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = { Service = "s3.amazonaws.com" }, Action = "sqs:SendMessage", Resource = aws_sqs_queue.notify.arn,
      Condition = { ArnEquals = { "aws:SourceArn" = aws_s3_bucket.uploads.arn }, StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}
