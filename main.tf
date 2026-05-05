# Create AMI from existing instance
resource "aws_ami_from_instance" "dr_ami" {
  name               = "${var.project_name}-${var.environment}-${formatdate("YYYY-MM-DD", timestamp())}"
  source_instance_id = var.source_instance_id
  
  tags = {
    Name        = "${var.project_name}-${var.environment}-ami"
    Environment = var.environment
  }
}


# Launch Template
resource "aws_launch_template" "dr_template" {
  name_prefix   = "${var.project_name}-${var.environment}-template"
  image_id      = aws_ami_from_instance.dr_ami.id
  instance_type = var.instance_type

  network_interfaces {
    associate_public_ip_address = true
    security_groups            = [var.security_group_id]
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo "DR instance startup script"
              EOF
  )

  tags = {
    Name        = "${var.project_name}-${var.environment}-template"
    Environment = var.environment
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "dr_asg" {
  name                = "${var.project_name}-${var.environment}-asg"
  desired_capacity    = 0
  max_size           = 1
  min_size           = 0
  target_group_arns  = [aws_lb_target_group.dr_tg.arn]
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.dr_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value              = "${var.project_name}-${var.environment}-asg"
    propagate_at_launch = true
  }
}

# Application Load Balancer
resource "aws_lb" "dr_alb" {
  name               = "${var.project_name}-${var.environment}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.security_group_id]
  subnets           = var.subnet_ids

  tags = {
    Name        = "${var.project_name}-${var.environment}-alb"
    Environment = var.environment
  }
}

# ALB Target Group
resource "aws_lb_target_group" "dr_tg" {
  name     = "${var.project_name}-${var.environment}-tg"
  port     = 8000
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 30
    timeout             = 5
    path                = "/"
    port                = "traffic-port"
    unhealthy_threshold = 2
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-tg"
    Environment = var.environment
  }
}

# ALB Listener
resource "aws_lb_listener" "dr_listener" {
  load_balancer_arn = aws_lb.dr_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = var.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dr_tg.arn
  }
}

# Route53 Record for testing
resource "aws_route53_record" "dr_test" {
  zone_id = var.hosted_zone_id
  name    = "prod-dr.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.dr_alb.dns_name
    zone_id                = aws_lb.dr_alb.zone_id
    evaluate_target_health = true
  }
}

