# Build Log: EKS Managed GitOps

Running journal of what broke, what surprised me, and how it got fixed.
Source material for the Medium article and the LinkedIn post.

---

## 2026-10-27

### ssh-agent disabled by default on Windows

The OpenSSH Authentication Agent service is set to **Disabled** out of the box on Windows. Running `ssh-add` or any Git operation that needs the agent silently fails until you fix it. Fix requires an elevated shell:

```powershell
# Run as Administrator
Set-Service ssh-agent -StartupType Automatic
Start-Service ssh-agent
```

Ordinary (non-admin) terminals can then use the agent normally after that.

---

### git not found after winget install (stale PATH)

`winget install Git.Git` completed successfully, but the existing terminal session still reported `git : The term 'git' is not recognized`. The terminal inherited the old `PATH` snapshot from before the install. Fix: open a new terminal (or reload the profile). No reinstall needed.

---

### AWS CLI NoRegion error — AWS_PROFILE not set in new terminals

New terminal sessions didn't pick up `AWS_PROFILE`, so the CLI defaulted to no profile and threw a `NoRegionError`. Fixed by persisting the variable at the user (machine) level with `setx`:

```powershell
setx AWS_PROFILE <profile-name>
```

Takes effect in any terminal opened after that point. Existing sessions still need a manual `$env:AWS_PROFILE = '<profile-name>'`.

---

### Managed Argo CD requires IAM Identity Center first

Tried to enable the EKS managed Argo CD add-on and hit a hard blocker: the managed capability requires IAM Identity Center (SSO) to be configured before the add-on can be provisioned. Nothing else in the GitOps stack can move forward until that prerequisite is in place. Setting up IAM Identity Center is the next step.

---
