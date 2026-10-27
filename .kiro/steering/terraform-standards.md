---
inclusion: always
---

# Terraform Standards (hard-won lessons)

## General
- Pin Terraform and the hashicorp/aws provider in `versions.tf`. Use a recent 6.x provider so `aws_eks_capability` is available.
- Never hardcode account IDs, region names, AZ names, or ARNs. Use `data "aws_caller_identity"`, `data "aws_region"`, `data "aws_availability_zones"`.
- Every input gets a `description` and `type`. Every output gets a `description`.
- Always run `terraform fmt` and `terraform validate` before planning.
- Always read the `terraform plan` add/change/destroy counts out loud before any apply. If the count is surprising, stop.

## EKS specifics
- Enable Auto Mode with `compute_config`, `kubernetes_network_config.elastic_load_balancing`, and `storage_config.block_storage` all set together. Partial Auto Mode config fails.
- Use `access_config.authentication_mode = "API"` and manage access with `aws_eks_access_entry`, not the aws-auth ConfigMap.
- Grant Matt's SSO role cluster admin via an access entry so `kubectl` works after `aws eks update-kubeconfig`.
- Tag private subnets `kubernetes.io/role/internal-elb = 1` and public subnets `kubernetes.io/role/elb = 1`.

## Argo CD capability
- The capability IAM role trust policy must allow the EKS capabilities service principal; follow the EKS "capability IAM role" doc exactly.
- Identity Center instance ARN and the admin group ID come in as variables, never inline.
- After create, status goes CREATING -> ACTIVE. Verify with `aws eks describe-capability` before applying Argo CD Applications.

## Cost and teardown
- Create the AWS Budget alarm in `budget.tf` so it exists from the first apply.
- Before `terraform destroy`, delete Argo CD Applications and any `LoadBalancer` Services first, or the ELBs they created can block VPC deletion.
