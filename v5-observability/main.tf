terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_lb" "calculator" {
  name = "calculator-v4-alb"
}

data "aws_lb_target_group" "calculator" {
  name = "calculator-v4-tg"
}

data "aws_sns_topic" "ops_alerts" {
  name = "ops-lab-alerts"
}

locals {
  alb_arn_suffix = data.aws_lb.calculator.arn_suffix
  tg_arn_suffix  = data.aws_lb_target_group.calculator.arn_suffix
  asg_name       = "calculator-v4-asg"
  rds_id         = "calculator-v2-db"
}

# --- Dashboard ---

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "calculator-ops-lab"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB Requests & Response Time"
          region = "us-east-1"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.alb_arn_suffix, { stat = "Average", yAxis = "right" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title  = "ALB Errors & Target Health"
          region = "us-east-1"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.tg_arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", local.alb_arn_suffix, "TargetGroup", local.tg_arn_suffix, { stat = "Average" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title  = "ASG Instance CPU"
          region = "us-east-1"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", local.asg_name, { stat = "Average" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "Instance Disk & Memory (CloudWatch Agent)"
          region = "us-east-1"
          metrics = [
            ["CalculatorOpsLab", "disk_used_percent", "path", "/", { stat = "Average" }],
            ["CalculatorOpsLab", "mem_used_percent", { stat = "Average" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6,
        properties = {
          title  = "RDS Health"
          region = "us-east-1"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.rds_id, { stat = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.rds_id, { stat = "Average", yAxis = "right" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6,
        properties = {
          title  = "RDS Free Storage"
          region = "us-east-1"
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", local.rds_id, { stat = "Average" }]
          ]
        }
      }
    ]
  })
}

# --- Alarms, all routed to the existing ops-lab-alerts SNS topic ---

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "calculator-alb-high-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "More than 5 server errors in 5 minutes"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
  }
  alarm_actions = [data.aws_sns_topic.ops_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "calculator-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 0
  alarm_description   = "At least one target failing health checks"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = local.alb_arn_suffix
    TargetGroup  = local.tg_arn_suffix
  }
  alarm_actions = [data.aws_sns_topic.ops_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "asg_high_cpu" {
  alarm_name          = "calculator-asg-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods   = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ASG average CPU above 80% for 10 minutes"
  treat_missing_data  = "notBreaching"
  dimensions = {
    AutoScalingGroupName = local.asg_name
  }
  alarm_actions = [data.aws_sns_topic.ops_alerts.arn]
}

output "dashboard_url" {
  value = "https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
