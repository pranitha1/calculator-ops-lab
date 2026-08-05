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

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d", "us-east-1f"]
  }
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "aws_security_group" "rds" {
  vpc_id = data.aws_vpc.default.id
  filter {
    name   = "group-name"
    values = ["calculator-v2-rds-sg"]
  }
}

# --- Security groups ---

resource "aws_security_group" "alb" {
  name        = "calculator-v4-alb-sg"
  description = "Public HTTP entry point"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app" {
  name        = "calculator-v4-app-sg"
  description = "App instances only accept traffic from the ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "App port from ALB only"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = "ops-lab-ec2-ssm-role"
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/calculator-ops-lab/app"
  retention_in_days = 14
}

resource "aws_security_group_rule" "rds_from_v4_app" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.rds.id
  source_security_group_id = aws_security_group.app.id
  description              = "Postgres from v4 ASG app instances"
}

# --- Launch template + Auto Scaling Group ---

resource "aws_launch_template" "calculator" {
  name_prefix   = "calculator-v4-"
  image_id      = data.aws_ami.al2023.id
  instance_type = "t3.micro"

  iam_instance_profile {
    name = "ops-lab-ec2-ssm-role"
  }

  vpc_security_group_ids = [aws_security_group.app.id]
  user_data               = base64encode(file("${path.module}/bootstrap.sh"))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "calculator-v4-asg"
    }
  }
}

resource "aws_autoscaling_group" "calculator" {
  name                = "calculator-v4-asg"
  min_size            = 0
  max_size            = 2
  desired_capacity    = 0
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.calculator.arn]
  health_check_type   = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.calculator.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "calculator-v4-asg"
    propagate_at_launch = true
  }
}

# --- ALB ---

resource "aws_lb" "calculator" {
  name               = "calculator-v4-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "calculator" {
  name     = "calculator-v4-tg"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.calculator.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.calculator.arn
  }
}

# --- Self-signed cert imported into ACM (no owned domain, learning TLS termination) ---

resource "aws_acm_certificate" "self_signed" {
  private_key      = file("${path.module}/key.pem")
  certificate_body = file("${path.module}/cert.pem")
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.calculator.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.self_signed.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.calculator.arn
  }
}

output "alb_dns_name" {
  value = aws_lb.calculator.dns_name
}
