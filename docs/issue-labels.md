# Issue Labels

This page explains what the labels on issues and pull requests in Forum Virium Helsinki repositories mean, who applies them, and how to add one. The agent-facing reference with the full rules is the [`github-labels` skill](https://github.com/laurigates/claude-plugins/blob/main/git-plugin/skills/github-labels/SKILL.md) in `laurigates/claude-plugins`.

## The label families

An open issue carries one **type** label, at least one **routing** label (`area:` or `core:`), and one **project** label. The **waiting** labels are added only while something stops the issue being picked up.

| Family | Labels | Says |
|--------|--------|------|
| Type | `bug`, `enhancement`, `chore`, `docs`, `security`, `refactor` | The kind of change. One per issue or PR |
| Routing: area | `area:<name>` | The part of the repository the issue is about: a directory, service or subsystem |
| Routing: core | `core:ci`, `core:quality`, `core:agent`, `core:build`, `core:components`, `core:docs` | Repo-wide machinery that belongs to no single area |
| Project | `project:<name>` | The org project board the issue belongs to. Workflows add the item to that board |
| Waiting | `needs:hardware`, `needs:decision`, `needs:human` | The issue waits on a person, normally its assignee |
| Waiting | `blocked` | The issue waits on another issue, PR or upstream change |

`area:` names differ per repository. A repository without a taxonomy file uses only the type, `core:`, project and waiting labels.

The other labels in the standard set (`dependencies`, `image-update`, `autorelease: *`, `user-feedback`, `feedback:*` and so on) are applied by specific automation. Leave them to it.

## Where each label is defined

Every label is declared in [`infrastructure/github/labels.tf`](https://github.com/ForumViriumHelsinki/infrastructure/blob/main/github/labels.tf) (FVH members only). That file is authoritative: any label it does not declare is deleted at the next `infrastructure-github` apply, and with it its use on every issue. Do not create labels with `gh label create` or in the GitHub UI.

| Labels | Where in `labels.tf` | Applied to |
|--------|---------------------|------------|
| Type, `core:*`, `needs:*`, `blocked`, `project:*` | `standard_labels` | Every Terraform-managed repository |
| `area:*` | `repo_extra_labels`, under the repository's name | That repository only |

The paths and title scopes that select each `area:` label are in the repository's own `.github/issue-labels.json`.

## The waiting labels

Unattended agents and scheduled routines skip an issue that carries any of these. Assign the issue to the person it waits on.

| Label | Added when | Removed when |
|-------|-----------|--------------|
| `needs:hardware` | The next step needs physical access: a device, a sensor, a bench check or a measurement. The issue says what to do and what to report | The result is posted |
| `needs:decision` | Work stopped on a choice that belongs to the assignee or a maintainer. A comment gives the options and a recommendation | The decision is recorded in a comment |
| `needs:human` | The work can land only with a person's live session, credentials or local data, or needs a manual step such as approving a Terraform Cloud apply | The work lands |
| `blocked` (blocker is an issue) | A `blocked_by` dependency link is added to the issue | The issue-labels workflow removes it when the last linked blocker in the same repository closes |
| `blocked` (blocker is a PR or upstream change) | A comment names the PR or upstream change | By hand, when that blocker lands |

No automation removes a `needs:` label.

## Automatic labelling

Repositories that call [`reusable-issue-labels.yml`](../.github/workflows/reusable-issue-labels.yml) get labels applied and checked from their taxonomy file:

- **New, reopened or edited issue**: type and routing labels are derived from the title (`fix(argocd): …` or `[Bug] argocd: …`). If the title gives no routing label, paths quoted in the body are used.
- **New, updated or edited PR**: the type label comes from the title, and a routing label from each changed file. Fork PRs and Dependabot PRs are skipped, and a caller can switch PR labelling off.
- Labels are only ever added. A group (type, or one routing prefix) that already has a label is left alone.
- **Issue closed**: `blocked` is removed from issues whose linked blockers are all closed.
- **Scheduled audit**: lists open issues with no type label, no routing label, `blocked` with no link, an open blocker link without `blocked`, or a `needs:` label older than 30 days. The results go to the job summary and one rolling issue. A manual `backfill` run labels open issues that lack a type or routing label.

The workflow's file header lists which event runs which job. The workflow never creates labels, so a label must exist before it can be applied.

## Adding an `area:` label

1. Declare the label in `repo_extra_labels` in `infrastructure/github/labels.tf`, under the repository's name.
2. After the `infrastructure-github` apply, add an entry to the repository's `.github/issue-labels.json` with the paths and title scopes that select it. The file format is in the [`github-labels` skill](https://github.com/laurigates/claude-plugins/blob/main/git-plugin/skills/github-labels/SKILL.md).

To rename a label, add the new name, relabel the existing issues, then remove the old name. Removing a name from `labels.tf` deletes the label from every issue.
