---
root: false
targets: ["claudecode", "copilot", "geminicli", "cursor"]
description: "CI/CD workflow conventions — call org reusable workflows, no inline logic"
globs: ["**/.github/workflows/**"]
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

| Caller Workflow | Reusable Workflow | Trigger | Org Secret |
|----------------|-------------------|---------|------------|
| `release-please.yml` | `reusable-release-please.yml` | Push to `main` | `MY_RELEASE_PLEASE_TOKEN` |
| `container-build.yml` | `reusable-container-build.yml` | release-please PR (PR phase) | — |
| `container-release.yml` | `reusable-container-release.yml` | Published release (release phase) | — |
| `auto-merge-image-updater.yml` | `reusable-auto-merge-image-updater.yml` | `image-updater-**` branches | `AUTO_MERGE_PAT` |
| `claude.yml` | `reusable-claude.yml` | Issue/PR @-mentions | `CLAUDE_CODE_OAUTH_TOKEN` |

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

## Build-Once/Promote Pattern

Container workflows use a two-phase pattern:

1. **PR phase** (`reusable-container-build.yml`): Builds `:next-{version}` pre-release image during release-please PR
2. **Release phase** (`reusable-container-release.yml`): Promotes pre-built image to semver tags via manifest-only retag (seconds, not minutes) + runs Trivy scan
3. Fallback rebuild if pre-built image is not found

## GitHub Actions Constraints

### No GitHub Code Security (GHAS)

The FVH org does not have GitHub Code Security enabled. The following are **forbidden in workflows**:

- `github/codeql-action/upload-sarif`
- `aquasecurity/trivy-action` with `upload-to-github-security: true`
- Any step using `security-events: write` permission

These will fail with `403` on private repos.

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
