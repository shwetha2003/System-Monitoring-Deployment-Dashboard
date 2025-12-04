terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 3.0"
    }
  }
  
  backend "s3" {
    bucket = "monitoring-terraform-state"
    key    = "production/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC
resource "aws_vpc" "monitoring_vpc" {
  cidr_block = "10.0.0.0/16"
  
  tags = {
    Name = "monitoring-vpc"
    Environment = var.environment
  }
}

# Subnets
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.monitoring_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"
  
  tags = {
    Name = "monitoring-public-subnet"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.monitoring_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"
  
  tags = {
    Name = "monitoring-private-subnet"
  }
}

# Security Groups
resource "aws_security_group" "monitoring_sg" {
  name        = "monitoring-security-group"
  description = "Security group for monitoring infrastructure"
  vpc_id      = aws_vpc.monitoring_vpc.id
  
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }
  
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "monitoring-security-group"
  }
}

# EC2 Instances
resource "aws_instance" "monitoring_server" {
  ami           = "ami-0c55b159cbfafe1f0"
  instance_type = var.instance_type
  subnet_id     = aws_subnet.public_subnet.id
  key_name      = aws_key_pair.monitoring_key.key_name
  
  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]
  
  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }
  
  user_data = <<-EOF
              #!/bin/bash
              apt-get update
              apt-get install -y docker.io docker-compose
              systemctl start docker
              systemctl enable docker
              
              # Create deployment directory
              mkdir -p /opt/monitoring
              EOF
  
  tags = {
    Name = "monitoring-server"
    Environment = var.environment
  }
}

# Database (RDS)
resource "aws_db_instance" "monitoring_db" {
  identifier     = "monitoring-db"
  engine         = "postgres"
  engine_version = "13.7"
  instance_class = var.db_instance_type
  
  allocated_storage     = 20
  storage_type         = "gp2"
  storage_encrypted    = true
  
  username = "postgres"
  password = var.db_password
  
  vpc_security_group_ids = [aws_security_group.monitoring_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.monitoring_db_subnet.name
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  
  tags = {
    Name = "monitoring-database"
  }
}

resource "aws_db_subnet_group" "monitoring_db_subnet" {
  name       = "monitoring-db-subnet"
  subnet_ids = [aws_subnet.private_subnet.id]
}

# S3 Bucket for backups
resource "aws_s3_bucket" "monitoring_backups" {
  bucket = "monitoring-backups-${var.environment}"
  
  tags = {
    Name        = "Monitoring Backups"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "backup_versioning" {
  bucket = aws_s3_bucket.monitoring_backups.id
  
  versioning_configuration {
    status = "Enabled"
  }
}

# CloudWatch Alarms
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "monitoring-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "300"
  statistic           = "Average"
  threshold           = "80"
  
  dimensions = {
    InstanceId = aws_instance.monitoring_server.id
  }
  
  alarm_description = "This metric monitors EC2 CPU utilization"
  alarm_actions     = [aws_sns_topic.alerts.arn]
}

# SNS Topic for alerts
resource "aws_sns_topic" "alerts" {
  name = "monitoring-alerts"
}

resource "aws_sns_topic_subscription" "email_alerts" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Outputs
output "instance_public_ip" {
  value = aws_instance.monitoring_server.public_ip
}

output "database_endpoint" {
  value = aws_db_instance.monitoring_db.endpoint
}

output "grafana_url" {
  value = "https://${aws_instance.monitoring_server.public_ip}:3000"
}
