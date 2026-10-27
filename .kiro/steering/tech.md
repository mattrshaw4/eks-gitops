---
inclusion: always
---

# Tech Stack and Environment

## Workstation
- **OS:** Windows 11 (x64), Lenovo laptop
- **Shell:** PowerShell 7 (`pwsh`). Write every command for PowerShell, not bash.
  - Line continuation is a backtick (`` ` ``), not a backslash.
  - Environment variables: `$env:AWS_PROFILE = "eks-lab"`, not `export`.
  - Use `Remove-Item`, `Get-Content`, `Select-String` (or the aliases rm, cat, sls). No `grep`, `sed`, `awk`.
- **Editor/agent:** Kiro IDE

## Tooling (installed via winget)
| Tool | Purpose | Check |
|---|---|---|
| Git | Version control, GitHub over SSH | `git --version` |
| AWS CLI v2 | Auth (IAM Identity Center SSO), EKS commands | `aws --version` |
| Terraform | All infrastructure | `terraform -version` |
| kubectl | Cluster inspection and break-it testing | `kubectl version --client` |

## AWS
- **Auth:** IAM Identity Center (SSO) profile named `eks-lab`. Never use long-lived access keys.
  Refresh with `aws sso login --profile eks-lab`.
- **Region:** set by the `region` Terraform variable (default `us-east-1`). Never hardcode it elsewhere.
- **Identity Center is mandatory:** the managed Argo CD capability only authenticates through it (no local Argo CD users).

## Platform choices
- **EKS Auto Mode** for compute. No managed node groups, no self-managed Karpenter.
- **Kubernetes version:** latest available on EKS at build time (1.36 as of Oct 2026). Verify with
  `aws eks describe-cluster-versions` before pinning.
- **Managed Argo CD:** `aws_eks_capability` resource (type `ARGOCD`) in the hashicorp/aws provider.
  If the provider version lacks a needed argument, check the provider changelog before falling back to the AWS CLI.
- **App source:** this public GitHub repo, path `apps/`. Public repo means Argo CD needs no repo credentials in v1.

## Agent rules for commands
- Ask before running `terraform apply`, `terraform destroy`, or any `kubectl delete`. Never auto-approve these.
- Always show the `terraform plan` resource summary (add/change/destroy counts) and wait for Matt to confirm.
- Prefer read-only commands (`get`, `describe`, `plan`) when investigating.
