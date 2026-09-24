---
root: false
targets: ["claudecode", "copilot", "antigravity-cli", "cursor"]
description: "FVH org delta for GitHub issue/PR metadata — project routing, project:* labels, Terraform-managed labels"
globs: ["**/*"]
---
# GitHub Metadata Hygiene — FVH Org Delta

The shared baseline (assignee, type label, reviewer, backfill) lives in the portfolio rule `~/repos/.claude/rules/github-metadata-hygiene.md`; this file adds only the FVH org delta.

**Project is required.** Every issue gets a project (`-p <title>`) and, where the table defines one, its `project:*` label — the label drives automated board routing. A PR takes the same project and label as its linked issue, and always links one (`Closes #N`). Backfill a missing project when touching an issue or PR. If the context does not clearly map to one row, ask before proceeding.

| Project | Label | Context signals |
|---|---|---|
| ICT | `project:ict` | General infrastructure, IT operations, cross-cutting concerns |
| Reusable Workflow Migration | `project:reusable-workflows` | CI/CD, `.github/workflows/`, reusable workflow adoption |
| Template: Epic | — | Epic-level planning and tracking |
| Gateway API Migration | `project:gateway-migration` | Gateway, ingress, networking |
| TFDS | `project:tfds` | TFDS app and services; **SIMPL-Open / `simpl-eval` / `simpl-eval-common` / `gke-simpl-eval` cluster** (cost code 313) |
| Thelma | `project:thelma` | Theme, UI, design system |
| Application Evaluator | `project:app-evaluator` | The Application Evaluator tool only — **NOT `simpl-eval`** (name collision; that is TFDS) |
| R4C Digital Twin | `project:r4c` | R4C, Cesium, 3D visualization |
| Platform Automation | `project:platform-automation` | Terraform, ArgoCD, platform tooling, infrastructure repo |
| Kyverno Policies | `project:kyverno` | Security policies, admission control |
| Cost Attribution Tooling | `project:cost-attribution` | `fvh-cost-attribution`, monthly cost reports, FinOps |

**The docs label is `documentation`**, not `docs`.

**No `triage` label.** `infrastructure/github/labels.tf` defines none. For an issue whose root cause is unconfirmed, use `bug` with a `triage(scope): ...` title prefix; do not request a `triage` label without first confirming a workflow needs one — the prefix has sufficed in practice.

**Labels are Terraform-managed** in `infrastructure/github/labels.tf` (`local.standard_labels`). A `gh label create` is destroyed on the next apply; add the label to `labels.tf` and apply via Terraform Cloud (`infrastructure-github` workspace).
