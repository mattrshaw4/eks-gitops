---
inclusion: always
---

# Project Structure

```
eks-gitops/
├── .kiro/
│   ├── steering/          # product, tech, structure, terraform-standards, build-journal
│   ├── specs/             # Kiro specs (one folder per feature)
│   └── hooks/             # Kiro agent hooks
├── infra/                 # Terraform root module
│   ├── versions.tf        # terraform + provider version pins
│   ├── providers.tf
│   ├── variables.tf
│   ├── vpc.tf             # VPC, subnets, NAT
│   ├── eks.tf             # EKS cluster with Auto Mode
│   ├── iam.tf             # cluster role, node role, Argo CD capability role
│   ├── argocd.tf          # aws_eks_capability (ARGOCD) + Identity Center RBAC mapping
│   ├── budget.tf          # AWS Budget alarm
│   └── outputs.tf
├── argocd/                # Argo CD Application / AppProject manifests (applied once, then GitOps takes over)
├── apps/
│   └── kitchen-ticket/    # The demo app's Kubernetes manifests (Deployment, Service, ConfigMap)
├── docs/
│   ├── build-log.md       # Running journal of what broke and why (article source material)
│   └── screenshots/
├── .gitattributes
├── .gitignore
└── README.md
```

## Conventions
- One concern per `.tf` file. File names describe the AWS thing, not the step number.
- Kubernetes manifests: one resource kind per file, named `<kind>.yaml` (e.g. `deployment.yaml`).
- Every resource gets tags/labels: `project = "eks-gitops"`, `owner = "matt-shaw"`.
- Screenshots for the article go in `docs/screenshots/` named `NN-short-description.png`.
