---
root: false
targets: ["claudecode", "copilot", "geminicli", "cursor"]
description: "GitHub issue and PR metadata standards — assignee, labels, project routing, label hygiene"
globs: ["**/*"]
---
# GitHub Metadata Hygiene

## Rule: Every issue and PR must have complete metadata — enforce on every GitHub interaction

### Trigger Points

Apply these checks when:
1. **Creating** issues or PRs — set all metadata at creation time
2. **Commenting or reviewing** existing issues/PRs — check for gaps and backfill
3. **Before opening a PR** — verify the target issue has proper metadata

### Issue Metadata Checklist

| Field | Required | How to Set | Default |
|-------|----------|-----------|---------|
| Assignee | Always | `-a @laurigates` | `laurigates` unless told otherwise |
| Labels | Always | `-l <name>` | At minimum a type label: `bug`, `enhancement`, `chore`, `documentation`, `security` |
| Project | Always | `-p <title>` | Determine from context (see project table below); ask if ambiguous |
| Milestone | If exists | `--milestone <name>` | Set if a relevant milestone exists for the repo |
| Issue type | If supported | MCP `issue_write` with `type` param | Check `list_issue_types` for the org first |
| Linked PR | When applicable | PR body `Closes #N` or `gh issue develop` | Link when creating PRs that address the issue |

### PR Metadata Checklist

| Field | Required | How to Set | Default |
|-------|----------|-----------|---------|
| Reviewer | If not author | `-r @laurigates` | `laurigates` unless told otherwise; **skip if user is the PR author** (GitHub API rejects self-review requests with HTTP 422) |
| Assignee | Always | `-a @laurigates` | `laurigates` unless told otherwise |
| Labels | Always | `-l <name>` | Match linked issue labels; add type label if missing |
| Project | Always | `-p <title>` | Same project as linked issue |
| Linked issue | Always | PR body with `Closes #N` / `Fixes #N` | Reference the issue being addressed |

**Self-review guard:** Before requesting a reviewer, check the PR author. If the requested reviewer matches the PR author, skip the `--add-reviewer` / `-r` flag entirely. Use separate `gh` commands for reviewer vs. other metadata to avoid a single 422 failing the entire update.

### Project Determination

Match context to the appropriate org project. Use repository name, file paths, and task description as signals. When a corresponding `project:*` label is defined in the table below, always apply it when creating issues/PRs — this label drives automated project board routing.

| # | Project | Label | Context Signals |
|---|---------|-------|----------------|
| 1 | ICT | `project:ict` | General infrastructure, IT operations, cross-cutting concerns |
| 2 | Reusable Workflow Migration | `project:reusable-workflows` | CI/CD workflows, `.github/workflows/`, reusable workflow adoption |
| 3 | Template: Epic | — | Epic-level planning and tracking |
| 4 | Gateway API Migration | `project:gateway-migration` | Gateway, ingress, networking changes |
| 5 | TFDS | `project:tfds` | TFDS application and related services |
| 6 | Thelma | `project:thelma` | Theme, UI, design system work |
| 7 | Application Evaluator | `project:app-evaluator` | Application evaluation tooling |
| 8 | R4C Digital Twin | `project:r4c` | R4C, Cesium, 3D visualization |
| 9 | Platform Automation | `project:platform-automation` | Terraform, ArgoCD, platform tooling, infrastructure repo |
| 10 | Kyverno Policies | `project:kyverno` | Security policies, admission control |
| 11 | Cost Attribution Tooling | `project:cost-attribution` | `fvh-cost-attribution` repo, cost attribution, monthly cost reports, FinOps tooling |

If context doesn't clearly map to one project, ask the user before proceeding.

### Backfill on Existing Issues/PRs

When interacting with an issue or PR that has missing metadata:

1. Add missing assignee (`laurigates`) and reviewer (`laurigates` for PRs — skip if author matches reviewer)
2. Add missing type labels — infer from title and content
3. Add to the appropriate project if not yet linked
4. Inform the user what was added (do not silently modify)

### Label Conventions

Use these standard type labels consistently:

| Label | When |
|-------|------|
| `bug` | Defect or broken behavior |
| `enhancement` | New feature or improvement to existing feature |
| `chore` | Maintenance, dependency updates, refactoring |
| `documentation` | Documentation changes |
| `security` | Security-related fixes or improvements |

Check available labels with `gh label list -R <owner>/<repo>` before applying — do not create labels that don't exist without asking.

**No `triage` label.** The org does not currently define a `triage` label in `infrastructure/github/labels.tf`. For investigation-stage issues where the root cause is not yet confirmed, use the `bug` label with a `triage(scope): ...` conventional-commit title prefix to signal the diagnostic intent. Do not request a `triage` label be added without first confirming the workflow needs one — the title prefix has been sufficient in practice.

**Labels are Terraform-managed.** Org-wide labels are defined in `infrastructure/github/labels.tf` (`local.standard_labels`). Do not create labels via `gh label create` — they will be destroyed on the next Terraform apply. To add a new label, add it to `labels.tf` and apply via Terraform Cloud (`infrastructure-github` workspace).
