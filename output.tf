output "dr_asg_name" {
  description = "Name of the DR Auto Scaling Group"
  value       = aws_autoscaling_group.dr_asg.name
}

output "dr_alb_dns" {
  description = "DNS name of the DR Application Load Balancer"
  value       = aws_lb.dr_alb.dns_name
}

output "dr_test_domain" {
  description = "DR test domain name"
  value       = aws_route53_record.dr_test.name
}