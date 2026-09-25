---
description: >-
  FVH org delta for GitHub issue/PR metadata — project routing, project:*
  labels, Terraform-managed labels
applyTo: '**/*'
---
# GitHub Metadata Hygiene — FVH Org Delta

**Baseline.** Assign `laurigates` unless told otherwise. Set a type label (`bug`, `enhancement`, `chore`, `documentation`, `security`), checking `gh label list -R <owner>/<repo>` first. Set the milestone where one fits, and the issue type where the org defines them (`list_issue_types`, then MCP `issue_write` with `type`). Request a reviewer only when they are not the PR author: GitHub rejects self-review with HTTP 422, so run the reviewer update as its own `gh` call. When touching an issue or PR with gaps, backfill them and tell the user what was added.

The FVH org delta:

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
| Internal Tools | `project:internal-tools` | FVH-internal staff tools: `silverbucket-helper`, apps in the `internal-tools` ArgoCD namespace |

**The docs label is `documentation`**, not `docs`.

**No `triage` label.** `infrastructure/github/labels.tf` defines none. For an issue whose root cause is unconfirmed, use `bug` with a `triage(scope): ...` title prefix; do not request a `triage` label without first confirming a workflow needs one — the prefix has sufficed in practice.

**Labels are Terraform-managed** in `infrastructure/github/labels.tf` (`local.standard_labels`). A `gh label create` is destroyed on the next apply; add the label to `labels.tf` and apply via Terraform Cloud (`infrastructure-github` workspace).
