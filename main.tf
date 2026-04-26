terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Empty provider block! Terraform will grab credentials from Jenkins environment variables automatically.
provider "aws" {
  region = "us-east-1"
}

# Pointing to the public key in the root directory of your repo
resource "aws_key_pair" "labsuser" {
  key_name   = "labsuser"
  public_key = file("${path.module}/labsuser.pub") 
}

# Default VPC and Subnets
resource "aws_default_vpc" "default" {}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [aws_default_vpc.default.id]
  }
}

# Security Group for Load Balancer
resource "aws_security_group" "alb_sg" {
  name        = "ALB-SG"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
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

# Security Group for EC2
resource "aws_security_group" "MySG" {
  name        = "EC2-App-SG"
  description = "Allow SSH and App Port"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch Template (Replaces aws_instance for Auto Scaling)
resource "aws_launch_template" "app_lt" {
  name_prefix   = "app-launch-template-"
  image_id      = "ami-0ec10929233384c7f" # Ubuntu 24.04 LTS
  instance_type = "t3.micro"
  key_name      = aws_key_pair.labsuser.key_name
  
  network_interfaces {
    security_groups             = [aws_security_group.MySG.id]
    associate_public_ip_address = true
  }

  # Updated for Ubuntu (apt instead of yum, ubuntu user instead of ec2-user)
  user_data = base64encode(<<-EOF
            #!/bin/bash
              
              # 1. Update and install standard packages
              apt-get update -y
              apt-get install -y docker.io git
              
              # 2. Ensure Docker is running
              systemctl start docker
              systemctl enable docker
              
              # 3. Add user to docker group
              usermod -aG docker ubuntu
              
              # 4. Clone the repository
              git clone https://github.com/Chanveasna-ENG/Deploy-Pipeline.git /home/ubuntu/app
              cd /home/ubuntu/app
              
              # 5. Build and run the docker image
              docker build -t evilsna/deploy-pipeline:v1.0 .
              docker run --name deploy-app -d -p 5000:5000 evilsna/deploy-pipeline:v1.0
              EOF
  )
}

# Application Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

# Target Group for ALB
resource "aws_lb_target_group" "app_tg" {
  name     = "app-target-group"
  port     = 5000
  protocol = "HTTP"
  vpc_id   = aws_default_vpc.default.id

  health_check {
    path                = "/"
    port                = "5000"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3
    interval            = 30
  }
}

# ALB Listener
resource "aws_lb_listener" "app_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "app_asg" {
  name                = "app-autoscaling-group"
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.app_tg.arn]
  
  # Starts with 1 instance, scales up to 3 when CPU gets too high
  min_size         = 1
  desired_capacity = 1
  max_size         = 3

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "WebServer-ASG-Instance"
    propagate_at_launch = true
  }
}

# Auto Scaling Policy (Triggers on 10% CPU to make it scale easily)
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "cpu-scaling-policy"
  policy_type            = "TargetTrackingScaling"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    # Set to 10% so that spamming refresh or opening tabs might trigger it!
    target_value = 10.0
  }
}

# Output the Load Balancer DNS Name
output "website-url" {
  value = "http://${aws_lb.app_lb.dns_name}"
}