resource "aws_sns_topic" "alarms" {
  name              = "${local.name}-alarms"
  kms_master_key_id = "alias/aws/sns"
}
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarms = {
    api-5xx = {
      namespace = "AWS/ApiGateway", metric = "5xx", stat = "Sum", threshold = 5, op = "GreaterThanThreshold"
      dims      = { ApiId = aws_apigatewayv2_api.api.id }
    }
    api-lambda-errors = {
      namespace = "AWS/Lambda", metric = "Errors", stat = "Sum", threshold = 5, op = "GreaterThanThreshold"
      dims      = { FunctionName = aws_lambda_function.fn["api"].function_name }
    }
    marking-dlq = {
      namespace = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum", threshold = 0, op = "GreaterThanThreshold"
      dims      = { QueueName = aws_sqs_queue.marking_dlq.name }
    }
    notify-dlq = {
      namespace = "AWS/SQS", metric = "ApproximateNumberOfMessagesVisible", stat = "Maximum", threshold = 0, op = "GreaterThanThreshold"
      dims      = { QueueName = aws_sqs_queue.notify_dlq.name }
    }
    db-cpu = {
      namespace = "AWS/RDS", metric = "CPUUtilization", stat = "Average", threshold = 80, op = "GreaterThanThreshold"
      dims      = { DBClusterIdentifier = aws_rds_cluster.db.cluster_identifier }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "a" {
  for_each            = local.alarms
  alarm_name          = "${local.name}-${each.key}"
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.stat
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  dimensions          = each.value.dims
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = local.name
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title   = "API requests / 5xx", region = var.region, stat = "Sum", period = 60,
          metrics = [["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.api.id], [".", "5xx", ".", "."]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title   = "Lambda concurrency / errors", region = var.region, stat = "Maximum", period = 60,
          metrics = [["AWS/Lambda", "ConcurrentExecutions", "FunctionName", aws_lambda_function.fn["api"].function_name], [".", "Errors", ".", ".", { stat = "Sum" }]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title   = "Aurora ACU / connections", region = var.region, stat = "Average", period = 60,
          metrics = [["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", aws_rds_cluster.db.cluster_identifier], [".", "DatabaseConnections", ".", "."]]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title   = "Queue depth", region = var.region, stat = "Maximum", period = 60,
          metrics = [["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", aws_sqs_queue.marking.name], [".", ".", ".", aws_sqs_queue.notify.name]]
        }
      }
    ]
  })
}
