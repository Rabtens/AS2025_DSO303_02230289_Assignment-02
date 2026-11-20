output "site_url" {
  value = "https://${local.custom_domain ? var.domain_name : aws_cloudfront_distribution.cdn.domain_name}"
}
output "cloudfront_distribution_id" { value = aws_cloudfront_distribution.cdn.id }
output "user_pool_id" { value = aws_cognito_user_pool.main.id }
output "user_pool_client_id" { value = aws_cognito_user_pool_client.web.id }
output "uploads_bucket" { value = aws_s3_bucket.uploads.id }
output "db_cluster_id" { value = local.db_cluster_id }
output "vpc_id" { value = aws_vpc.main.id }
output "private_app_subnet_ids" { value = aws_subnet.app[*].id }
output "public_subnet_ids" { value = aws_subnet.public[*].id }
output "marking_dlq_url" { value = aws_sqs_queue.marking_dlq.url }
