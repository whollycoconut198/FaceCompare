# Provider configuration
provider "aws" {
  region = "us-east-1" # Adjust region as needed
}

# VPC
resource "aws_vpc" "face_compare_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.face_compare_vpc.id
}

# Subnets
resource "aws_subnet" "public_subnet_1" {
  vpc_id                  = aws_vpc.face_compare_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_subnet_2" {
  vpc_id                  = aws_vpc.face_compare_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private_subnet_1" {
  vpc_id                  = aws_vpc.face_compare_vpc.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id                  = aws_vpc.face_compare_vpc.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.face_compare_vpc.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.face_compare_vpc.id
}

# Routes
resource "aws_route" "public_internet_access" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# NAT Gateway
resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet_1.id
}

resource "aws_route" "private_nat_access" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

# Route Table Associations
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private.id
}

# Security Groups
resource "aws_security_group" "alb_sg" {
  vpc_id      = aws_vpc.face_compare_vpc.id
  description = "Security group for ALB"

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

resource "aws_security_group" "instance_sg" {
  vpc_id      = aws_vpc.face_compare_vpc.id
  description = "Security group for EC2 instances"

  ingress {
    from_port       = 8000
    to_port         = 8000
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

# ALB
resource "aws_lb" "app_lb" {
  name               = "facecompare-load-balancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet_1.id, aws_subnet.public_subnet_2.id]
}

resource "aws_lb_target_group" "tg" {
  port                 = 8000
  protocol             = "HTTP"
  vpc_id               = aws_vpc.face_compare_vpc.id
  target_type          = "instance"
  
  health_check {
    interval            = 30
    path                = "/"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# Launch Template and AutoScaling Group
resource "aws_launch_template" "lt" {
  name_prefix   = "face-compare-lt"
  image_id      = "ami-0f4d13f30a278024b"
  instance_type = "t4g.small"

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.instance_sg.id]
  }
}

resource "aws_autoscaling_group" "asg" {
  vpc_zone_identifier = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
  
  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  min_size         = 1
  max_size         = 10
  desired_capacity = 1
  
  target_group_arns = [aws_lb_target_group.tg.arn]
}

# Scaling Policy
resource "aws_autoscaling_policy" "scaling_policy" {
  name                   = "cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"
  
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

# Data block for AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Outputs
output "load_balancer_dns" {
  description = "DNS name of the load balancer"
  value       = aws_lb.app_lb.dns_name
}