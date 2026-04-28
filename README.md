# Disaster Recovery — Warm Standby Stack

Terraform module that provisions a **pilot-light / warm-standby** disaster-recovery environment for the etc production application. On each apply it snapshots a live production EC2 instance into a dated AMI, then stands up a full replacement stack — Launch Template, Auto Scaling Group (scaled to zero), Application Load Balancer over HTTPS, Route 53 record — ready to be scaled up in seconds when the primary fails. The ASG stays at `desired_capacity = 0` in steady state to keep running cost minimal.

## Highlights

- **Pilot-light topology** — ASG `desired = 0, min = 0, max = 1` means no instances run until you scale up, so monthly cost is dominated by the ALB only (no EC2 billing in steady state).
- **AMI from live prod on every apply** — `aws_ami_from_instance` takes a fresh snapshot of `var.source_instance_id` each time Terraform runs, and the AMI name is datestamped (`${project}-${env}-YYYY-MM-DD`), giving a clean history of DR snapshots.
- **HTTPS-first** — ALB listener is HTTPS-only on :443 with `ELBSecurityPolicy-2016-08` and a customer-supplied ACM certificate; health check on `/`.
- **Route 53 integration** — creates a Route 53 alias `prod-dr.<domain>` pointing at the DR ALB so failover is a DNS flip — or you can point it at the live ALB today and flip at incident time.
- **All wiring externalised** — VPC, subnets, SG, certificate, hosted zone, domain, and source instance ID are all variables (no hardcoded IDs). `terraform.tfvars` supplies the values.

## Architecture

```
 Prod instance (source_instance_id)
          │
          ▼  on `terraform apply`:
 aws_ami_from_instance (${project}-${env}-YYYY-MM-DD)
          │
          ▼
 Launch Template  ──► ASG (desired=0, max=1)  ──► Target Group :80
                                                       │
                                                       ▼
                                            ALB (HTTPS :443, ACM cert)
                                                       │
                                                       ▼
                                        Route 53  prod-dr.<domain>
```

On a disaster event:
1. Scale the ASG to `desired = 1`.
2. The new instance boots from the last-captured AMI.
3. Traffic follows the Route 53 record to the DR ALB.

## Tech stack

- **Terraform** >= 1.x, AWS provider ~> 4.0
- **AWS services:** EC2 AMI, Launch Template, Auto Scaling Group, Application Load Balancer, ACM, Route 53

## Repository layout

```
DR-SETUP/
├── README.md
├── .gitignore
├── main.tf                # AMI, Launch Template, ASG, ALB, listener, Route 53
├── variables.tf           # vpc_id, subnet_ids, instance_type, source_instance_id, hosted_zone_id, certificate_arn, ...
└── terraform.tfvars       # values for the variables
```

## How it works

1. Terraform reads `var.source_instance_id` and snapshots it into a new AMI named `${project}-${environment}-YYYY-MM-DD`.
2. A Launch Template references that AMI and associates a public IP + the supplied SG.
3. The ASG uses that Launch Template across `var.subnet_ids`, with capacity pinned to 0 so nothing runs by default.
4. An HTTPS-only ALB on :443 points at a new Target Group with a health check on `/`; the ALB listener uses `var.certificate_arn`.
5. A Route 53 A-alias `prod-dr.${domain_name}` points at the ALB.

## Prerequisites

- Terraform >= 1.x
- AWS CLI configured with permissions for `ec2:*`, `autoscaling:*`, `elasticloadbalancing:*`, `route53:ChangeResourceRecordSets`, `acm:DescribeCertificate`
- An existing production EC2 instance (`source_instance_id`)
- An ACM certificate in the same region as the ALB
- An existing Route 53 hosted zone
- An existing VPC + subnets + security group

# Optional: flip your production Route 53 record to point at the DR ALB
```

## Teardown

```bash
terraform destroy
```

## Notes

- Captured AMIs are NOT garbage-collected automatically — add a lifecycle rule or periodic prune script if running this on a schedule.
- The ALB is internet-facing — gate access with a Web ACL if exposing DR externally.
- Demonstrates: pilot-light DR pattern, AMI-based snapshot strategy, HTTPS-only ALB with ACM, DNS-driven failover, ASG-as-warm-standby.
