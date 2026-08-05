terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_caller_identity" "current" {}

resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_db_subnet_group" "calculator" {
  name       = "calculator-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "rds" {
  name        = "calculator-v2-rds-sg"
  description = "Allow Postgres from the calculator app instance only"
  vpc_id      = data.aws_vpc.default.id

  # Ingress is intentionally NOT defined inline here. The actual rule
  # (5432 from the v4 ASG's app security group) is owned exclusively by
  # aws_security_group_rule.rds_from_v4_app in v4-asg-alb/main.tf. Mixing
  # an inline ingress block on this resource with a separate
  # aws_security_group_rule targeting the same SG causes Terraform to
  # treat this block as authoritative and revert/remove the real rule
  # on every apply - this bit us for real, do not re-add it.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "calculator" {
  identifier              = "calculator-v2-db"
  engine                  = "postgres"
  engine_version          = "16.4"
  instance_class          = "db.t3.micro"
  allocated_storage       = 25
  db_name                 = "calculator"
  username                = "calcadmin"
  password                = random_password.db.result
  db_subnet_group_name    = aws_db_subnet_group.calculator.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  storage_encrypted       = true
  backup_retention_period = 1
  skip_final_snapshot     = true
  apply_immediately       = true
}

resource "aws_ssm_parameter" "db_host" {
  name  = "/calculator/db_host"
  type  = "String"
  value = aws_db_instance.calculator.address
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/calculator/db_name"
  type  = "String"
  value = aws_db_instance.calculator.db_name
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/calculator/db_user"
  type  = "String"
  value = aws_db_instance.calculator.username
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/calculator/db_password"
  type  = "SecureString"
  value = random_password.db.result
}

resource "aws_iam_role_policy" "ssm_params" {
  name = "calculator-ssm-parameter-read"
  role = "ops-lab-ec2-ssm-role"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/calculator/*",
        "arn:aws:ssm:us-east-1:${data.aws_caller_identity.current.account_id}:parameter/cloudwatch-agent"
      ]
    }]
  })
}

resource "aws_sns_topic" "ops_alerts" {
  name = "ops-lab-alerts"
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops_alerts.arn
  protocol  = "email"
  endpoint  = "ypranitha1@gmail.com"
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "calculator-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2000000000
  alarm_description   = "RDS free storage below 2GB - practice disk sizing response"
  dimensions = {
    DBInstanceIdentifier = aws_db_instance.calculator.id
  }
  alarm_actions = [aws_sns_topic.ops_alerts.arn]
}

output "db_endpoint" {
  value = aws_db_instance.calculator.address
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}

output "ops_alerts_topic_arn" {
  value = aws_sns_topic.ops_alerts.arn
}
