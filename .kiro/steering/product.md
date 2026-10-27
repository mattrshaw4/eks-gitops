---
inclusion: always
---

# Product: EKS Managed GitOps Portfolio Project

## What this is
A portfolio project that builds an Amazon EKS cluster with Terraform and delivers an application
through the **managed Argo CD capability** (EKS Capabilities). The finished build is written up as
a Medium technical article and a LinkedIn "Terraforming My Career" post.

## Owner
Matt Shaw, cloud engineer (kitchen-to-cloud career changer). Kitchen analogies are welcome in
comments, READMEs, and the build journal.

## Goals
1. Provision EKS (Auto Mode, latest Kubernetes version EKS offers) entirely with Terraform.
2. Enable the managed Argo CD capability, authenticated through AWS IAM Identity Center.
3. Deploy a small app from this GitHub repo: a git push to `apps/` must change what runs in the cluster.
4. Deliberately break things (bad image tag, manual drift with kubectl, deleted pods) and document how GitOps recovers.
5. Tear everything down cleanly with `terraform destroy` and record the actual cost.

## Non-goals
- No production hardening beyond sensible defaults (no multi-account, no multi-region).
- No self-managed Argo CD install. The point is the managed capability.
- No ACK or kro in v1. They are possible follow-ups.

## Success criteria
- `terraform apply` builds the full stack from zero; `terraform destroy` removes it with nothing left billing.
- Argo CD UI reachable via Identity Center sign-in and shows the app Synced and Healthy.
- Every failure, surprise, and fix is logged in `docs/build-log.md` (raw material for the articles).

## Cost guardrails
- An AWS Budget alarm exists before the first apply.
- Work in focused sessions; destroy at the end of every session unless Matt says otherwise.
