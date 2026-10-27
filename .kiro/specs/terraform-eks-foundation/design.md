# Design Document

## Overview

This document describes the technical design for the `terraform-eks-foundation` Terraform module. The module lives entirely under `infra/` in the workspace root and provisions a lab-grade AWS environment from a single `terraform apply`: a two-AZ VPC, an EKS cluster with Auto Mode enabled, API-mode cluster authentication backed by IAM Identity Center, and an AWS Budget alarm. No external Terraform modules are used; all resources are authored directly against the AWS provider to keep the dependency surface minimal and the configuration fully auditable.

**Key design goals:**
- Every environment-specific value flows through a declared variable — no hard-coded account IDs, region strings, or CIDRs in resource bodies.
- `terraform destroy` leaves zero orphaned resources.
- The module fails loudly at plan time if the Identity Center role lookup is ambiguous.
- EKS Auto Mode replaces standalone Karpenter, EBS CSI, and AWS Load Balancer Controller — no Helm releases or managed addons are needed after `apply`.

---

## Architecture

### High-Level Provisioning Order

```
variables.tf / terraform.tf
        │
        ▼
data.tf  ──────────────────────────────────────────────────────┐
  data.aws_availability_zones                                    │
  data.aws_caller_identity                                       │
  data.aws_iam_roles (Identity Center SSO role)                 │
        │                                                        │
        ▼                                                        │
networking.tf                                                    │
  aws_vpc                                                        │
  aws_subnet ×4 (2 public, 2 private)                           │
  aws_internet_gateway                                           │
  aws_eip (NAT)                                                  │
  aws_nat_gateway                                                │
  aws_route_table ×2 + aws_route_table_association ×4            │
        │                                                        │
        ▼                                                        │
iam.tf                                                           │
  aws_iam_role.cluster + policy attachments ×5                   │
  aws_iam_role.node   + policy attachments ×2                    │
        │                                                        │
        ▼                                                        │
eks.tf                                                           │
  aws_eks_cluster (Auto Mode, API auth, private subnets)  ◄─────┘
        │
        ▼
access.tf
  aws_eks_access_entry (Identity Center role → STANDARD)
  aws_eks_access_policy_association (AmazonEKSClusterAdminPolicy / Cluster scope)
        │
        ▼
budget.tf
  aws_budgets_budget

outputs.tf
  cluster_name, cluster_endpoint, cluster_ca_data, cluster_oidc_issuer_url
```

### Networking Topology

```
Region: var.region
┌────────────────────────────────────────────────────────────────────────┐
│  VPC  (var.vpc_cidr, default 10.0.0.0/16)                              │
│                                                                        │
│  ┌─────────────────────────────┐  ┌─────────────────────────────┐     │
│  │  AZ[0]  (e.g. us-east-1a)  │  │  AZ[1]  (e.g. us-east-1b)  │     │
│  │                             │  │                             │     │
│  │  public-0  (10.0.0.0/24)   │  │  public-1  (10.0.2.0/24)   │──── IGW ──► Internet
│  │    NAT GW ──────────────────┼──┼──────► (no NAT in AZ[1])   │     │
│  │                             │  │                             │     │
│  │  private-0 (10.0.1.0/24)  │  │  private-1 (10.0.3.0/24)  │     │
│  │    EKS nodes               │  │    EKS nodes               │     │
│  └─────────────────────────────┘  └─────────────────────────────┘     │
│                                                                        │
│  Route tables:                                                         │
│    public-rt:   0.0.0.0/0 → IGW                                       │
│    private-rt:  0.0.0.0/0 → NAT GW (single, in public-0)             │
└────────────────────────────────────────────────────────────────────────┘
```

A single NAT Gateway is placed in the first public subnet (`public-0`). Both private subnets share a single private route table pointing to that NAT Gateway. This is intentional for a lab environment — it reduces cost and complexity while still providing outbound internet access for all private subnets. A production design would use one NAT Gateway per AZ for HA.

---

## Components and Interfaces

### File Layout

| File | Contents |
|---|---|
| `infra/terraform.tf` | `terraform {}` block with required providers and minimum Terraform version |
| `infra/providers.tf` | `provider "aws"` with `region`, `default_tags`, and optional `assume_role` |
| `infra/variables.tf` | All input variable declarations |
| `infra/data.tf` | All `data` source lookups |
| `infra/networking.tf` | VPC, subnets, IGW, NAT GW, EIP, route tables, associations |
| `infra/iam.tf` | Cluster IAM role + attachments, node IAM role + attachments |
| `infra/eks.tf` | `aws_eks_cluster` resource (Auto Mode) |
| `infra/access.tf` | `aws_eks_access_entry` + `aws_eks_access_policy_association` |
| `infra/budget.tf` | `aws_budgets_budget` |
| `infra/outputs.tf` | All output values |
| `infra/terraform.tfvars.example` | Example values for every variable |

### terraform.tf

```hcl
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

Terraform 1.9+ is required because the `aws_iam_roles` precondition uses cross-object references in `lifecycle` blocks (available since 1.2) and the `validation` block on `api_allowed_cidrs` uses `contains()`. The AWS provider must be `~> 6.0` because earlier 5.x versions lack the `compute_config`, `storage_config`, and `kubernetes_network_config.elastic_load_balancing` arguments on `aws_eks_cluster`, and the 6.x provider introduces `aws_eks_capability` required for future specs.

### providers.tf

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project = "eks-gitops"
      owner   = "matt-shaw"
    }
  }
}
```

`default_tags` replaces all per-resource tag blocks for the `project` and `owner` keys. No individual resource may re-declare these two keys.

---

## Data Models

### Variables (`variables.tf`)

| Variable | Type | Default | Required | Validation |
|---|---|---|---|---|
| `region` | `string` | — | yes | none |
| `cluster_name` | `string` | `"eks-lab"` | no | none |
| `kubernetes_version` | `string` | `"1.36"` | no | none; description documents "latest Auto Mode-supported version at authoring time" |
| `vpc_cidr` | `string` | `"10.0.0.0/16"` | no | none |
| `availability_zones` | `list(string)` | `[]` | no | length 0 or 2; empty list triggers data source fallback |
| `api_allowed_cidrs` | `list(string)` | — | yes | `!contains(var.api_allowed_cidrs, "0.0.0.0/0")` |
| `budget_limit_amount` | `string` | `"30"` | no | none |
| `budget_currency` | `string` | `"USD"` | no | none |
| `budget_notification_emails` | `list(string)` | — | yes | `length >= 1 && length <= 10` |

> **Note on `availability_zones`:** The variable is optional (`default = []`). When empty, `data.aws_availability_zones` fetches the region's AZ list at plan time and the configuration uses `slice(..., 0, 2)` to pick the first two in lexicographic order (which is the order the data source returns them). When the operator supplies two explicit AZ names, those are used directly, with no data source call needed.

> **Note on `api_allowed_cidrs` validation:** The validation uses `!contains(var.api_allowed_cidrs, "0.0.0.0/0")` with the error message: `"api_allowed_cidrs must not contain 0.0.0.0/0; supply one or more specific CIDR ranges instead."` This is a `variable` block `validation` (not a lifecycle precondition) so it fires at plan time before any API calls.

### Local Values

A `locals` block (placed at the top of `networking.tf`) resolves the effective AZ list:

```hcl
locals {
  azs = length(var.availability_zones) == 2 ? var.availability_zones : slice(
    data.aws_availability_zones.available.names, 0, 2
  )
}
```

Subnet CIDR blocks are derived from the VPC CIDR using `cidrsubnet`:

```hcl
# Public subnets:  10.0.0.0/24, 10.0.2.0/24
# Private subnets: 10.0.1.0/24, 10.0.3.0/24
public_subnet_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 0), cidrsubnet(var.vpc_cidr, 8, 2)]
private_subnet_cidrs = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 3)]
```

This interleaving keeps public and private subnets paired by index within each AZ.

### Data Sources (`data.tf`)

```hcl
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_roles" "identity_center_admin" {
  name_regex  = "AWSReservedSSO_AdministratorAccess_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "aws_region" "current" {}
```

The `data.aws_iam_roles.identity_center_admin.arns` attribute returns a set. The precondition (see Access section below) enforces exactly one match.

---

## Networking (`networking.tf`)

### Resources

- `aws_vpc.main` — DNS hostnames and DNS support enabled (required for EKS).
- `aws_subnet.public[0..1]` — `map_public_ip_on_launch = true`, tagged with `kubernetes.io/role/elb = 1` and `kubernetes.io/cluster/<cluster_name> = shared`.
- `aws_subnet.private[0..1]` — tagged with `kubernetes.io/role/internal-elb = 1` and `kubernetes.io/cluster/<cluster_name> = shared`.
- `aws_internet_gateway.main` — attached to the VPC.
- `aws_eip.nat` — `domain = "vpc"`; `depends_on = [aws_internet_gateway.main]` to ensure IGW exists before the EIP allocation.
- `aws_nat_gateway.main` — placed in `aws_subnet.public[0]`.
- `aws_route_table.public` — single route `0.0.0.0/0 → aws_internet_gateway.main.id`.
- `aws_route_table.private` — single route `0.0.0.0/0 → aws_nat_gateway.main.id`.
- `aws_route_table_association` × 4 — associates each subnet with the appropriate route table.

EKS subnet discovery tags are applied as resource-level tags on the subnet resources using `merge()` to combine them with any additional tags from default_tags. Since `project` and `owner` are already in default_tags, the subnet `tags` argument only contains the EKS-specific keys.

```hcl
tags = {
  "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  "kubernetes.io/role/elb"                    = "1"   # public only
}
```

---

## IAM Design (`iam.tf`)

### Cluster IAM Role

The cluster role trust policy must allow both `sts:AssumeRole` and `sts:TagSession` for `eks.amazonaws.com`. EKS Auto Mode requires `sts:TagSession` to propagate session tags used by the managed controllers (Karpenter, LBC, EBS CSI).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```

Policies attached via `aws_iam_role_policy_attachment` using `for_each` over a `toset()`:

```
arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
arn:aws:iam::aws:policy/AmazonEKSComputePolicy
arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy
arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy
arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy
```

The last four are Auto Mode-specific policies required for the built-in Karpenter, EBS CSI, Load Balancer Controller, and VPC CNI components.

### Node IAM Role

The node role trust policy allows `ec2.amazonaws.com` to assume the role (standard EC2 instance profile pattern, used by Auto Mode nodes internally):

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Policies attached:
```
arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy
arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly
```

`AmazonEKSWorkerNodeMinimalPolicy` (not the older `AmazonEKSWorkerNodePolicy`) is required for Auto Mode — the minimal policy grants only what Auto Mode nodes actually need, and the broader policy can cause unexpected behavior.

---

## EKS Cluster (`eks.tf`)

```hcl
resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API"
  }

  compute_config {
    enabled       = true
    node_pools    = ["general-purpose", "system"]
    node_role_arn = aws_iam_role.node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_public_access  = true
    endpoint_private_access = true
    public_access_cidrs     = var.api_allowed_cidrs
    security_group_ids      = []
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy_attachment.node,
  ]
}
```

**Implementation decisions:**

- `bootstrap_self_managed_addons = false` disables the default kube-proxy and vpc-cni add-ons that EKS would otherwise install, because Auto Mode manages networking internally.
- `authentication_mode = "API"` removes any ConfigMap dependency. The creator's IAM principal is NOT automatically granted cluster-admin (no `enable_cluster_creator_admin_permissions`); access is granted exclusively through the explicit access entry in `access.tf`.
- The `vpc_config` places control plane ENIs in private subnets only, with public endpoint access restricted to `api_allowed_cidrs`.
- `depends_on` on both IAM role policy attachments prevents a race condition where EKS tries to use the role before all policies are attached.

---

## Access Entries (`access.tf`)

### Identity Center Role Precondition

The `data.aws_iam_roles` data source returns a set of ARNs. A `lifecycle` precondition on the `aws_eks_access_entry` resource enforces exactly one match:

```hcl
resource "aws_eks_access_entry" "identity_center_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = one(data.aws_iam_roles.identity_center_admin.arns)
  type          = "STANDARD"

  lifecycle {
    precondition {
      condition = length(data.aws_iam_roles.identity_center_admin.arns) == 1
      error_message = <<-EOT
        Expected exactly 1 IAM role matching 'AWSReservedSSO_AdministratorAccess_*'
        under /aws-reserved/sso.amazonaws.com/, but found
        ${length(data.aws_iam_roles.identity_center_admin.arns)}.
        Verify that the AdministratorAccess permission set is assigned to at least
        one account in IAM Identity Center, and that no duplicate SSO roles exist
        under this path.
      EOT
    }
  }
}
```

Using a `lifecycle.precondition` (rather than a `variable` validation) is the correct pattern here because the check depends on a data source value that is resolved during the plan phase, not a user-supplied variable. `one()` is preferred over `tolist()[0]` because it returns `null` (rather than an index error) when the set is empty, making the error message from the `lifecycle.precondition` more readable than a panic.

### Access Policy Association

```hcl
resource "aws_eks_access_policy_association" "identity_center_admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.identity_center_admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.identity_center_admin]
}
```

The policy ARN namespace `arn:aws:eks::aws:cluster-access-policy/` is the documented prefix for all EKS-managed Kubernetes access policies. The `access_scope.type = "cluster"` grants permissions across all namespaces.

---

## Budget (`budget.tf`)

```hcl
resource "aws_budgets_budget" "monthly" {
  name              = "${var.cluster_name}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = var.budget_limit_amount
  limit_unit        = var.budget_currency
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_notification_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_notification_emails
  }
}
```

Two separate `notification` blocks are required — one for `FORECASTED` at 100% and one for `ACTUAL` at 80%. The `time_period_start` is a required field; a static past date is acceptable and has no effect on alerting.

---

## Outputs (`outputs.tf`)

| Output | Source | Description |
|---|---|---|
| `cluster_name` | `aws_eks_cluster.main.name` | Cluster name for use in `aws eks update-kubeconfig` |
| `cluster_endpoint` | `aws_eks_cluster.main.endpoint` | API server endpoint URL |
| `cluster_ca_data` | `aws_eks_cluster.main.certificate_authority[0].data` | Base64-encoded CA certificate |
| `cluster_oidc_issuer_url` | `aws_eks_cluster.main.identity[0].oidc[0].issuer` | OIDC issuer for IRSA configuration |
| `region` | `data.aws_region.current.region` | AWS region the cluster was deployed to |
| `kubeconfig_command` | `"aws eks update-kubeconfig --name ${aws_eks_cluster.main.name} --region ${data.aws_region.current.region} --profile eks-lab"` | Ready-to-run command to configure kubectl |

All outputs are marked `sensitive = false` — none contain credentials.

> The `kubeconfig_command` output is a convenience string that can be pasted directly into a PowerShell terminal to configure kubectl access after apply.

---

## Error Handling

### Plan-Time Failures

| Scenario | Mechanism | Message |
|---|---|---|
| `api_allowed_cidrs` contains `0.0.0.0/0` | `variable` validation block | Instructs operator to supply specific CIDR ranges |
| `availability_zones` list is neither empty nor exactly 2 items | `variable` validation block | Instructs operator to supply 0 or exactly 2 AZ names |
| `budget_notification_emails` length outside 1–10 | `variable` validation block | States the 1–10 constraint |
| Identity Center role count ≠ 1 | `lifecycle.precondition` on `aws_eks_access_entry` | Reports actual count and instructs operator to check IAM Identity Center assignment |

### Destroy Safety

> **Pre-destroy checklist:** EKS Auto Mode creates AWS resources outside of Terraform state — specifically, Elastic Load Balancers for `LoadBalancer`-type Services and EBS volumes for `PersistentVolumeClaim` resources. These are not tracked by Terraform and will NOT be removed by `terraform destroy`. If any workloads have been deployed to the cluster, delete all `LoadBalancer` Services and `PersistentVolumeClaims` from Kubernetes first (e.g. `kubectl delete svc --all -A`, `kubectl delete pvc --all -A`) and wait for the corresponding AWS resources to be deprovisioned before running `terraform destroy`. Failure to do this can leave orphaned ELBs and EBS volumes blocking VPC deletion.

No `local-exec` or `remote-exec` provisioners are used anywhere in the module. All AWS resources are managed exclusively through Terraform resource blocks, ensuring `terraform destroy` can cleanly remove everything in the Terraform state.

The EKS cluster and IAM roles have no deletion protection flags set, so destroy proceeds without manual intervention.

The `aws_eip.nat` resource uses `depends_on = [aws_internet_gateway.main]` to sequence the IGW before the EIP, which also ensures Terraform sequences the destroy in reverse (EIP before IGW) automatically.

---

## Testing Strategy

This feature is Terraform Infrastructure as Code. Property-based testing is not applicable — there are no pure functions with universally-quantifiable input/output behavior. Testing focuses on three complementary levels.

### 1. Static Analysis (Pre-Apply)

- **`terraform fmt -check`** — enforces canonical HCL formatting.
- **`terraform validate`** — catches type errors, missing required arguments, and undefined references without making API calls.
- **`terraform plan`** — performs a dry run against the target AWS account; reviews the plan diff to confirm the expected resource count and no unexpected replacements.
- **`tflint`** (optional) — catches provider-specific issues such as invalid instance types or deprecated argument names.

### 2. Post-Apply Verification Checks

Run these commands after `terraform apply` completes successfully (addresses Requirement 8):

```powershell
# 1. Cluster is ACTIVE
$clusterName = terraform -chdir=infra output -raw cluster_name
$region      = terraform -chdir=infra output -raw region
aws eks describe-cluster `
  --name $clusterName `
  --region $region `
  --query 'cluster.status' `
  --output text
# Expected: ACTIVE

# 2. Auto Mode NodePools exist
aws eks update-kubeconfig `
  --name $clusterName `
  --region $region `
  --profile eks-lab
kubectl get nodepools
# Expected: entries named general-purpose and system

# 3. Identity Center role has cluster-admin
$env:AWS_PROFILE = "eks-lab"
kubectl auth can-i '*' '*'
# Expected: yes
```

### 3. Snapshot / Drift Testing

- After a successful apply, run `terraform plan` again and confirm the output shows **"No changes."** This is the canonical IaC smoke test — it verifies the real infrastructure matches the Terraform state and that no resources have drifted.
- Before merging changes, run `terraform plan` and review for unexpected `forces replacement` annotations on the EKS cluster, IAM roles, or VPC (replacement of these resources causes downtime).

### 4. Destroy Validation

In a clean lab cycle:
1. `terraform apply`
   (review the plan, confirm resource counts, then approve at the prompt)
2. `terraform destroy`
   (review the destroy plan, confirm, then approve at the prompt)
3. Confirm the AWS console shows no remaining VPCs, EKS clusters, or IAM roles with the `eks-lab` prefix in the target account.
