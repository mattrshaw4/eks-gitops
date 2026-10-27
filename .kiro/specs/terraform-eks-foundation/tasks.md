# Implementation Plan: Terraform EKS Foundation

## Overview

Create the `infra/` directory and all Terraform configuration files that provision a two-AZ VPC, an EKS cluster with Auto Mode, API-mode authentication backed by IAM Identity Center, and an AWS Budget alarm. Files are created in dependency order so each step can be validated incrementally with `terraform validate`.

## Tasks

- [x] 1. Scaffold the `infra/` directory with provider and version constraints
  - [x] 1.1 Create `infra/terraform.tf` with required_version and AWS provider pin
    - Declare `terraform {}` block with `required_version = ">= 1.9.0"`
    - Declare `required_providers` block: `hashicorp/aws ~> 6.0`
    - _Requirements: 5.1_

  - [x] 1.2 Create `infra/providers.tf` with AWS provider configuration
    - Declare `provider "aws"` with `region = var.region`
    - Add `default_tags` block setting `project = "eks-gitops"` and `owner = "matt-shaw"`
    - _Requirements: 6.1, 6.2, 5.2_

- [x] 2. Declare all input variables and data sources
  - [x] 2.1 Create `infra/variables.tf` with all nine declared variables
    - Declare `region` (string, required), `cluster_name` (string, default `"eks-lab"`), `kubernetes_version` (string, default `"1.36"`)
    - Declare `vpc_cidr` (string, default `"10.0.0.0/16"`), `availability_zones` (list(string), default `[]`) with validation enforcing length 0 or 2
    - Declare `api_allowed_cidrs` (list(string), required) with validation rejecting `"0.0.0.0/0"` and error message instructing operator to supply specific CIDR ranges
    - Declare `budget_limit_amount` (string, default `"30"`), `budget_currency` (string, default `"USD"`), `budget_notification_emails` (list(string), required) with validation enforcing length between 1 and 10
    - Every variable must have a non-empty `description` and explicit `type`
    - _Requirements: 5.1, 5.2, 5.3, 4.2, 4.3_

  - [x] 2.2 Create `infra/data.tf` with all four data source lookups
    - Declare `data.aws_availability_zones.available` with `state = "available"` and `filter` block for `opt-in-not-required`
    - Declare `data.aws_caller_identity.current`
    - Declare `data.aws_iam_roles.identity_center_admin` with `name_regex = "AWSReservedSSO_AdministratorAccess_.*"` and `path_prefix = "/aws-reserved/sso.amazonaws.com/"`
    - Declare `data.aws_region.current`
    - _Requirements: 1.7, 3.2, 3.5_

- [ ] 3. Checkpoint — run `terraform init && terraform validate` inside `infra/`
  - Ensure all providers download cleanly and validate reports no errors before proceeding. Ask the user if questions arise.

- [ ] 4. Implement VPC networking
  - [ ] 4.1 Create `infra/networking.tf` with locals, VPC, subnets, and gateways
    - Add `locals` block at top of file: `azs` resolves to `var.availability_zones` when length is 2, else `slice(data.aws_availability_zones.available.names, 0, 2)`
    - Add `locals` entries for `public_subnet_cidrs` and `private_subnet_cidrs` derived via `cidrsubnet(var.vpc_cidr, 8, index)` using offsets 0/2 (public) and 1/3 (private)
    - Create `aws_vpc.main` with DNS hostnames and DNS support enabled
    - Create `aws_subnet.public` (count = 2): `map_public_ip_on_launch = true`, tags include `kubernetes.io/cluster/${var.cluster_name} = shared` and `kubernetes.io/role/elb = 1`
    - Create `aws_subnet.private` (count = 2): tags include `kubernetes.io/cluster/${var.cluster_name} = shared` and `kubernetes.io/role/internal-elb = 1`
    - Create `aws_internet_gateway.main` attached to the VPC
    - Create `aws_eip.nat` with `domain = "vpc"` and `depends_on = [aws_internet_gateway.main]`
    - Create `aws_nat_gateway.main` in `aws_subnet.public[0]`
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.6, 1.7_

  - [ ] 4.2 Add route tables and associations to `infra/networking.tf`
    - Create `aws_route_table.public` with route `0.0.0.0/0 → aws_internet_gateway.main.id`
    - Create `aws_route_table.private` with route `0.0.0.0/0 → aws_nat_gateway.main.id`
    - Create four `aws_route_table_association` resources associating each public subnet with the public route table and each private subnet with the private route table
    - _Requirements: 1.5_

- [ ] 5. Implement IAM roles for cluster and nodes
  - [ ] 5.1 Create `infra/iam.tf` with the EKS cluster IAM role
    - Create `aws_iam_role.cluster` with trust policy allowing `sts:AssumeRole` and `sts:TagSession` for `eks.amazonaws.com`
    - Attach the five Auto Mode policies via `aws_iam_role_policy_attachment.cluster` using `for_each` over a `toset()`: `AmazonEKSClusterPolicy`, `AmazonEKSComputePolicy`, `AmazonEKSBlockStoragePolicy`, `AmazonEKSLoadBalancingPolicy`, `AmazonEKSNetworkingPolicy`
    - _Requirements: 2.4_

  - [ ] 5.2 Add the EKS node IAM role to `infra/iam.tf`
    - Create `aws_iam_role.node` with trust policy allowing `sts:AssumeRole` for `ec2.amazonaws.com`
    - Attach two policies via `aws_iam_role_policy_attachment.node` using `for_each`: `AmazonEKSWorkerNodeMinimalPolicy`, `AmazonEC2ContainerRegistryPullOnly`
    - _Requirements: 2.5_

- [ ] 6. Checkpoint — run `terraform validate` inside `infra/`
  - Confirm no errors before creating the EKS cluster resource. Ask the user if questions arise.

- [ ] 7. Implement the EKS cluster
  - [ ] 7.1 Create `infra/eks.tf` with the `aws_eks_cluster` resource
    - Set `name`, `version = var.kubernetes_version`, `role_arn = aws_iam_role.cluster.arn`
    - Set `bootstrap_self_managed_addons = false`
    - Add `access_config { authentication_mode = "API" }`
    - Add `compute_config` block: `enabled = true`, `node_pools = ["general-purpose", "system"]`, `node_role_arn = aws_iam_role.node.arn`
    - Add `kubernetes_network_config { elastic_load_balancing { enabled = true } }`
    - Add `storage_config { block_storage { enabled = true } }`
    - Add `vpc_config` block: `subnet_ids = aws_subnet.private[*].id`, `endpoint_public_access = true`, `endpoint_private_access = true`, `public_access_cidrs = var.api_allowed_cidrs`
    - Add `depends_on` on both `aws_iam_role_policy_attachment.cluster` and `aws_iam_role_policy_attachment.node`
    - _Requirements: 2.1, 2.2, 2.3, 3.1_

- [ ] 8. Implement access entries and budget alarm
  - [ ] 8.1 Create `infra/access.tf` with the Identity Center access entry and policy association
    - Create `aws_eks_access_entry.identity_center_admin`: `principal_arn = one(data.aws_iam_roles.identity_center_admin.arns)`, `type = "STANDARD"`
    - Add `lifecycle.precondition` block: `condition = length(data.aws_iam_roles.identity_center_admin.arns) == 1`; error message must state the actual count found and instruct the operator to verify the AdministratorAccess permission set assignment in IAM Identity Center
    - Create `aws_eks_access_policy_association.identity_center_admin`: `policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"`, `access_scope { type = "cluster" }`, `depends_on = [aws_eks_access_entry.identity_center_admin]`
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

  - [ ] 8.2 Create `infra/budget.tf` with the monthly cost budget and two notification blocks
    - Create `aws_budgets_budget.monthly`: `budget_type = "COST"`, `time_unit = "MONTHLY"`, `limit_amount = var.budget_limit_amount`, `limit_unit = var.budget_currency`
    - Add first `notification` block: `notification_type = "FORECASTED"`, `threshold = 100`, `threshold_type = "PERCENTAGE"`, `comparison_operator = "GREATER_THAN"`, `subscriber_email_addresses = var.budget_notification_emails`
    - Add second `notification` block: `notification_type = "ACTUAL"`, `threshold = 80`, same comparator and subscriber list
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [ ] 9. Add Terraform outputs
  - [ ] 9.1 Create `infra/outputs.tf` with all six output values
    - Output `cluster_name` from `aws_eks_cluster.main.name`
    - Output `cluster_endpoint` from `aws_eks_cluster.main.endpoint`
    - Output `cluster_ca_data` from `aws_eks_cluster.main.certificate_authority[0].data`
    - Output `cluster_oidc_issuer_url` from `aws_eks_cluster.main.identity[0].oidc[0].issuer`
    - Output `region` from `data.aws_region.current.region`
    - Output `kubeconfig_command` as the interpolated string `"aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${data.aws_region.current.region} --profile eks-lab"`
    - Every output must have a non-empty `description`; none should be marked `sensitive`
    - _Requirements: 2.6_

- [ ] 10. Create the example variables file
  - [ ] 10.1 Create `infra/terraform.tfvars.example` listing all nine variables
    - Include every variable declared in `variables.tf` with a non-empty placeholder value
    - Each variable assignment must have an inline `#` comment of at least one word explaining its purpose
    - _Requirements: 5.4_

- [ ] 11. Final checkpoint — `terraform fmt` and `terraform validate`
  - Run `terraform fmt -recursive infra/` to enforce canonical HCL formatting.
  - Run `terraform validate` inside `infra/` and confirm the output is `"Success! The configuration is valid."`
  - Ask the user if questions arise.

- [ ] 12. Post-apply verification script
  - [ ] 12.1 Create `infra/verify.ps1` with the three post-apply verification checks
    - Read `cluster_name` and `region` from `terraform output -raw` (run from `infra/`)
    - Check 1: run `aws eks describe-cluster --name $clusterName --region $region --query 'cluster.status' --output text` and write a pass/fail message based on whether the output equals `ACTIVE`
    - Check 2: run `aws eks update-kubeconfig --name $clusterName --region $region --profile eks-lab` then `kubectl get nodepools` and confirm entries named `general-purpose` and `system` appear
    - Check 3: set `$env:AWS_PROFILE = "eks-lab"` then run `kubectl auth can-i '*' '*'` and confirm the output is `yes`
    - Use `Write-Host` for all output; use PowerShell 7 syntax throughout (backtick line continuation, `$env:` variables)
    - Do NOT include `-auto-approve` or any destructive flags
    - _Requirements: 8.1, 8.2, 8.3_

## Notes

- Tasks marked with `*` are optional and can be skipped for faster iteration — there are none in this plan because the design explicitly states property-based testing is not applicable to IaC.
- Each task references specific requirements for traceability.
- Checkpoints (tasks 3, 6, 11) use `terraform validate` which requires no AWS credentials and runs instantly.
- `terraform plan` and `terraform apply` require live AWS credentials (`aws sso login --profile eks-lab`) and are intentionally left to the operator — never run them automatically.
- The `verify.ps1` script (task 12.1) is only useful after a successful `terraform apply`; run it manually.

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2"] },
    { "id": 1, "tasks": ["2.1", "2.2"] },
    { "id": 2, "tasks": ["4.1"] },
    { "id": 3, "tasks": ["4.2", "5.1"] },
    { "id": 4, "tasks": ["5.2"] },
    { "id": 5, "tasks": ["7.1"] },
    { "id": 6, "tasks": ["8.1", "8.2"] },
    { "id": 7, "tasks": ["9.1"] },
    { "id": 8, "tasks": ["10.1"] },
    { "id": 9, "tasks": ["12.1"] }
  ]
}
```
