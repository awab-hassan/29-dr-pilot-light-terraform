# Project # 29 - dr-pilot-light-terraform

Terraform module that provisions a pilot-light disaster-recovery scaffold on AWS. On apply it snapshots a live production EC2 instance into a datestamped AMI, then stands up a complete replacement stack: Launch Template, Auto Scaling Group (scaled to zero), HTTPS Application Load Balancer with ACM, Target Group, and a Route 53 alias record. The ASG sits at `desired_capacity = 0` in steady state, keeping monthly cost dominated by the ALB rather than running EC2 hours.

## Architecture

```
Production instance (var.source_instance_id)
        |
        | terraform apply -> aws_ami_from_instance
        v
AMI: <project>-<environment>-YYYY-MM-DD
        |
        v
Launch Template -> ASG (desired=0, min=0, max=1) -> Target Group :80 (HTTP)
                                                          |
                                                          v
                                              ALB (HTTPS :443, ACM cert)
                                                          |
                                                          v
                                              Route 53: prod-dr.<domain>
```

### Failover

1. Scale the ASG to `desired = 1`. The new instance boots from the most recent AMI.
2. Traffic flows via the Route 53 record to the DR ALB. Alternatively, flip the production Route 53 record to point at the DR ALB at incident time.

## What It Provisions

- `aws_ami_from_instance` — fresh AMI of the source instance, datestamped per apply
- Launch Template referencing the new AMI; `associate_public_ip_address = true`
- Auto Scaling Group across the supplied subnets (`desired = 0, min = 0, max = 1`)
- Application Load Balancer (internet-facing) with HTTPS listener on port 443 using the supplied ACM certificate
- Target Group on port 80 / HTTP with health check on `/` (TLS terminates at the ALB)
- Route 53 A-alias `prod-dr.<domain>` pointing at the DR ALB

## Inputs

| Variable | Purpose |
|---|---|
| `source_instance_id` | Production EC2 instance to snapshot |
| `vpc_id` | Existing VPC for the DR stack |
| `subnet_ids` | Subnets for the ASG and ALB |
| `security_group_id` | Pre-existing security group |
| `instance_type` | Launch Template instance type |
| `certificate_arn` | ACM certificate for the HTTPS listener |
| `hosted_zone_id` | Route 53 hosted zone for the DNS record |
| `domain_name` | Domain for the `prod-dr.<domain>` alias |
| `project_name`, `environment` | Used in resource and AMI naming |

## Stack

Terraform 1.x · AWS provider · EC2 AMI · Launch Template · Auto Scaling Group · Application Load Balancer · ACM · Route 53

## Repository Layout

```
dr-pilot-light-terraform/
├── main.tf
├── variables.tf
├── terraform.tfvars       # Values (gitignored)
├── .gitignore
└── README.md
```

## Deployment

```bash
terraform init
terraform plan
terraform apply
```

## Teardown

```bash
terraform destroy
```

## Known Issues and Trade-offs

This module is functional but has known design choices and bugs that should be addressed before production use.

**AMI is recreated on every apply.** The AMI name uses `formatdate("YYYY-MM-DD", timestamp())`, and `timestamp()` is evaluated at every plan. This forces a new AMI (and a new Launch Template version) on every `terraform apply`, even when nothing else has changed. Mitigations:
- Add `lifecycle { ignore_changes = [name] }` to `aws_ami_from_instance`, or
- Move snapshot creation out of Terraform entirely and into a scheduled job (EventBridge + Lambda) that produces AMIs on a defined cadence rather than on every apply.

**ALB and EC2 share one security group.** `var.security_group_id` is applied to both the ALB and the Launch Template. Production setups should separate these: an ALB security group accepting 443 from the internet, and an instance security group accepting traffic only from the ALB SG on the app port.

**Instances get public IPs.** `associate_public_ip_address = true` on the Launch Template means DR instances are directly addressable from the internet. Best practice is private subnets for instances and public subnets only for the ALB.

**TLS terminates at the ALB.** Target group is HTTP on port 80. Traffic between the ALB and the EC2 instances is plaintext. If end-to-end encryption is required, switch the target group to HTTPS and run TLS on the instance.

**No HTTP-to-HTTPS redirect.** The ALB listens only on 443. Requests on port 80 fail rather than redirecting. Add a port 80 listener with a redirect action if browser clients are expected.

**TLS policy is dated.** `ELBSecurityPolicy-2016-08` includes older protocols. Use a modern policy such as `ELBSecurityPolicy-TLS13-1-2-2021-06` unless older clients must be supported.

**No AMI lifecycle policy.** Each apply creates a new AMI and underlying EBS snapshots. Without periodic cleanup, costs accumulate indefinitely. Add a lifecycle Lambda or use AWS Backup with a retention policy.

**Source instance reboots during snapshot.** `aws_ami_from_instance` defaults to rebooting the source for filesystem consistency. If running this against live production, schedule applies during a maintenance window or set `snapshot_without_reboot = true` only if the workload tolerates a crash-consistent snapshot.

**AMI is point-in-time.** Any data written to the source instance's local disk between snapshots is lost on failover. Persistent data should live in RDS, EFS, or S3, never on the EC2 root volume.
