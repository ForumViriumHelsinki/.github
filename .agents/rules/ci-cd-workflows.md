---
trigger: glob
globs: '**/.github/workflows/**'
---
# CI/CD Workflow Configuration

## Rule: Application repos MUST call org reusable workflows

All CI/CD logic is centralized in [`ForumViriumHelsinki/.github`](https://github.com/ForumViriumHelsinki/.github). Application repos call reusable workflows — do not duplicate build/release/security logic inline.

## Call Syntax

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/<name>.yml@main
```

## Standard Workflow Set for a Deployed Application

### Required Workflows

| Caller Workflow | Reusable Workflow | Trigger | Auth |
|----------------|-------------------|---------|------|
| `release-please.yml` | `reusable-release-please.yml` | Push to `main` | `app-id` + `APP_PRIVATE_KEY` (preferred) or `MY_RELEASE_PLEASE_TOKEN` (PAT, legacy) |
| `container-build.yml` | `reusable-container-build.yml` | release-please PR (PR phase) | — |
| `container-release.yml` | `reusable-container-release.yml` | Published release (release phase) | — |
| `auto-merge-image-updater.yml` | `reusable-auto-merge-image-updater.yml` | `image-updater-**` branches | `AUTO_MERGE_PAT` or `app-id` + `APP_PRIVATE_KEY` |
| `claude.yml` | `reusable-claude.yml` | Issue/PR @-mentions | `CLAUDE_CODE_OAUTH_TOKEN` (org secret; requires the `claude` topic in infrastructure `github/repos.json`) |

**Renovate is not a per-repo workflow.** It runs centrally from the infrastructure repo's `.github/workflows/renovate.yml`, which autodiscovers every `ForumViriumHelsinki/*` repository (infrastructure ADR-0036). Application repos may carry only a `renovate.json`; see dependency-automation.md.

**The Claude token is granted by repository topic.** `CLAUDE_CODE_OAUTH_TOKEN` is an organization secret delivered only to repositories carrying the `claude` topic in the infrastructure repo's `github/repos.json` (the selected-repository list is built from that file in `github/secrets_claude.tf`). This applies to every Claude-powered caller: `claude.yml`, `claude-review.yml`, and the `security-*` / `quality-*` / `a11y-*` workflows listed below. Three consequences:

- Terraform owns repository topics, so adding the topic in the GitHub UI neither grants the secret nor survives the next `infrastructure-github` apply; the secret reaches the repo only after that apply runs.
- Do not create a repository-level secret of the same name. It takes precedence over the organization secret and is not rotated with it.
- A repo with a caller but no grant fails with `Either ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN ... is required`. In `reusable-claude.yml` (@-mention) that step runs with `continue-on-error: true`, so the failure need not turn the job red.


### Workflow Input Reference

Inputs, secrets and outputs of the most-used reusable workflows are in sibling rules that load with this one:

| Rule | Covers |
|------|--------|
| `ci-cd-release-please.md` | `reusable-release-please.yml`, and why not to set `skip-on-release-commit` |
| `ci-cd-claude.md` | `reusable-claude.yml` inputs and the max-turns handoff |
| `ci-cd-packages.md` | `reusable-npm-publish.yml` and `reusable-bun-ci.yml` |

### Renovate Workflow Inputs (central infrastructure caller only)

`reusable-renovate.yml` accepts these inputs. Only the infrastructure repo calls it (ADR-0036); an application repo has no caller to configure.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `config-file` | string | `renovate.json` | Path to renovate config file |
| `log-level` | string | `info` | Renovate log level |
| `dry-run` | string | `false` | Dry run mode (`false`, `full`, `lookup`) |
| `app-id` | string | `''` | Renovate GitHub App **client ID** (a numeric App ID also works; the client ID is recommended). When set, generates an App token via `APP_PRIVATE_KEY` instead of using `GITHUB_TOKEN` |
| `bot-username` | string | `''` | `RENOVATE_USERNAME` (e.g. `fvh-renovate-bot[bot]`). Only applies when `app-id` is set. |
| `bot-git-author` | string | `''` | `RENOVATE_GIT_AUTHOR` full author string. Only applies when `app-id` is set. |
| `timeout-minutes` | number | `60` | Job timeout in minutes |
| `repositories` | string | `''` | Explicit `RENOVATE_REPOSITORIES` value (space- or comma-separated `owner/repo` slugs). Overrides the default of scanning only the calling repo. Ignored when `autodiscover` is enabled. |
| `autodiscover` | string | `'false'` | Set to `true` to autodiscover every repository the App installation can access (`RENOVATE_AUTODISCOVER`), optionally narrowed by `autodiscover-filter`. Takes precedence over `repositories`. |
| `autodiscover-filter` | string | `''` | `RENOVATE_AUTODISCOVER_FILTER` value (e.g. `ForumViriumHelsinki/*`) scoping autodiscovery. Only applies when `autodiscover` is `true`. |

When neither `autodiscover` nor `repositories` is set, the workflow scans only the calling repository.

Secrets:
- `APP_PRIVATE_KEY` — Renovate App private key. Required iff `app-id` is set.

Example — App-token caller (infrastructure repo):

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-renovate.yml@main
with:
  app-id: ${{ vars.RENOVATE_APP_ID }}
  bot-username: fvh-renovate-bot[bot]
  bot-git-author: fvh-renovate-bot <fvh-renovate-bot[bot]@users.noreply.github.com>
  autodiscover: 'true'
  autodiscover-filter: 'ForumViriumHelsinki/*'
secrets:
  APP_PRIVATE_KEY: ${{ secrets.RENOVATE_APP_PRIVATE_KEY }}
```

### Optional Workflows (Claude-Powered)

| Caller Workflow | Reusable Workflow | Purpose |
|----------------|-------------------|---------|
| `security-secrets.yml` | `reusable-security-secrets.yml` | Detect leaked secrets |
| `security-deps.yml` | `reusable-security-deps.yml` | Dependency vulnerability audit |
| `security-owasp.yml` | `reusable-security-owasp.yml` | OWASP Top 10 static analysis |
| `quality-code-smell.yml` | `reusable-quality-code-smell.yml` | Code smell detection |
| `quality-async.yml` | `reusable-quality-async.yml` | Async pattern validation |
| `quality-typescript.yml` | `reusable-quality-typescript.yml` | TypeScript strictness |
| `a11y-aria.yml` | `reusable-a11y-aria.yml` | ARIA pattern correctness |
| `a11y-wcag.yml` | `reusable-a11y-wcag.yml` | WCAG 2.1 compliance |

## Adoption Audit

When opening, editing, or reviewing a workflow file in any FVH application repo, briefly scan the rest of `.github/workflows/` and surface adoption gaps:

- Inline build/release/security/quality logic that duplicates a reusable workflow → propose migrating to `uses: ForumViriumHelsinki/.github/...`.
- Missing standard workflows for a deployed application (release-please, container build/release, image-updater auto-merge, claude).
- A per-repo `renovate.yml` in an application repo → propose removing it (ADR-0036).
- Pinned `@<sha>` / `@v1` references to reusable workflows — confirm they are intentional vs. drift from `@main`.

Surface findings in the response — do not silently rewrite unrelated workflow files. Migration to reusable workflows is a deliberate change. Workspace-wide adoption status is also visible via `just fvh::workflow-matrix` from the workspace root.

## Build-Once/Promote Pattern

Container workflows use a two-phase pattern:

1. **PR phase** (`reusable-container-build.yml`): Builds `:next-{version}` pre-release image during release-please PR
2. **Release phase** (`reusable-container-release.yml`): Promotes pre-built image to semver tags via manifest-only retag (seconds, not minutes) + runs Trivy scan
   - Image tags derive from the version left after stripping `tag-prefix`; a `tag-prefix` that does not prefix the release tag fails the run
3. Fallback rebuild if pre-built image is not found

## GitHub Actions Constraints

### No GitHub Code Security (GHAS)

The FVH org does not have GitHub Code Security enabled. The following are **forbidden in workflows**:

- `github/codeql-action/upload-sarif`
- `aquasecurity/trivy-action` with `upload-to-github-security: true`
- Any step using `security-events: write` permission

These will fail with `403` on private repos.

## Sentry Secrets Are Distributed by the Infrastructure Repo

A workflow step that talks to Sentry (release creation, source-map upload) reads `SENTRY_DSN`, `SENTRY_AUTH_TOKEN`, `SENTRY_PROJECT` and `SENTRY_ORG` from Actions secrets. No application repo manages these itself. Terraform in `ForumViriumHelsinki/infrastructure` distributes them:

| Secret | Scope | Source (`infrastructure/github/secrets_sentry.tf`) |
|--------|-------|--------|
| `SENTRY_DSN` | per-repo | GCP Secret Manager `sentry_dsn_<slug>`, written by the Sentry workspace. Only distributed once that secret exists. |
| `SENTRY_AUTH_TOKEN` | per-repo | GCP Secret Manager, one org-shared token |
| `SENTRY_PROJECT` | per-repo | The slug `lower(replace(repo, "/[^a-zA-Z0-9_-]/", "-"))` |
| `SENTRY_ORG` | org-level | `var.sentry_org_slug`, default `forum-virium-helsinki` |

Distribution is gated on the `sentry-enabled` topic in `infrastructure/github/repos.json` (archived and fork repos are skipped). The Sentry projects are created in `infrastructure/sentry/main.tf` (`sentry_project.all_github_repos`) with the same slug rule, which is how `SENTRY_PROJECT` resolves to a real project.

When a Sentry step fails with a missing-env error (example repo: `thelma`):

1. Confirm the repo carries the `sentry-enabled` topic in `infrastructure/github/repos.json`.
2. Check what is actually present: `gh secret list -R ForumViriumHelsinki/thelma` and `gh api repos/ForumViriumHelsinki/thelma/actions/organization-secrets`.
3. Fix a missing secret in the infrastructure repo. Do **not** run `gh secret set`: a hand-set secret is Terraform drift, and the next apply overwrites or removes it.

## Conventional Commits

release-please requires conventional commit messages:

| Prefix | Version bump |
|--------|-------------|
| `fix:` | Patch (0.0.x) |
| `feat:` | Minor (0.x.0) |
| `feat!:` or `BREAKING CHANGE:` footer | Major (x.0.0) |

## References

- Full workflow catalog and details: `@infrastructure/.claude/rules/reusable-workflows.md`
- Workflow adoption status: Run `just fvh::workflow-matrix` from workspace root
