---
trigger: always_on
---
# FVH Dev Kit Routing

FVH developers can install the **FVH dev kit** (`fvh-platform` plugin) at user level for Claude Code and Antigravity. It is private to the organization; installation is described in the FVH infrastructure wiki.

If its `fvh-*` skills are available, use them for FVH platform work instead of reconstructing the conventions from these rules:

| Task | Skill |
|------|-------|
| Make an app deployable: ArgoCD application, AppProject, Image Updater | `fvh-app-onboarding` |
| Write or fix `deploy/values.yaml` for the helm-webapp chart | `fvh-deploy-values` |
| Expose an app: hostname, gateway listener, timeouts | `fvh-expose-app` |
| Secrets, Cloud SQL, object storage | `fvh-app-secrets-and-data` |
| Feature flags, autoscaling, error tracking | `fvh-runtime-config` |
| Check a repo against FVH conventions | `fvh-compliance-check` |

If the skills are not available, follow the other FVH rules in this directory and say that the dev kit would give more specific guidance.
