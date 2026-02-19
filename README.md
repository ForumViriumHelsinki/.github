# ForumViriumHelsinki/.github

Organization-wide GitHub configuration for [Forum Virium Helsinki](https://forumviriumhelsinki.fi).

## What's here

| Path | Purpose |
|------|---------|
| `profile/README.md` | Org profile shown on [github.com/ForumViriumHelsinki](https://github.com/ForumViriumHelsinki) |
| `CODE_OF_CONDUCT.md` | Default code of conduct for all repos |
| `CONTRIBUTING.md` | Default contribution guidelines for all repos |
| `SECURITY.md` | Security vulnerability reporting policy |
| `SUPPORT.md` | Where to get help |
| `.github/ISSUE_TEMPLATE/` | Default issue templates for all repos |
| `.github/PULL_REQUEST_TEMPLATE.md` | Default PR template for all repos |
| `.github/workflows/reusable-*.yml` | Reusable workflows callable from any FVH repo |
| `workflow-templates/` | Starter workflows shown in Actions tab for new repos |

## Reusable Workflows

Call these from any FVH repo using `uses: ForumViriumHelsinki/.github/.github/workflows/<name>.yml@main`.

### Infrastructure

| Workflow | Description |
|----------|-------------|
| `reusable-container-build.yml` | Build and push Docker image to GHCR with Trivy scan |
| `reusable-release-please.yml` | Automated releases via release-please |
| `reusable-auto-merge-image-updater.yml` | Auto-merge ArgoCD Image Updater PRs |
| `reusable-renovate.yml` | Dependency updates via Renovate |
| `reusable-claude.yml` | Claude Code @-mention support in issues and PRs |

### Security (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-security-secrets.yml` | Detect leaked secrets and credentials |
| `reusable-security-deps.yml` | Dependency vulnerability audit |
| `reusable-security-owasp.yml` | OWASP Top 10 static analysis |

### Quality (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-quality-code-smell.yml` | Code smell and anti-pattern detection |
| `reusable-quality-async.yml` | Async pattern validation |
| `reusable-quality-typescript.yml` | TypeScript strictness analysis |

### Accessibility (Claude-powered)

| Workflow | Description |
|----------|-------------|
| `reusable-a11y-aria.yml` | ARIA pattern correctness |
| `reusable-a11y-wcag.yml` | WCAG 2.1 compliance check |

## Usage Example

```yaml
# In your repo's .github/workflows/ci.yml
jobs:
  build:
    uses: ForumViriumHelsinki/.github/.github/workflows/reusable-container-build.yml@main
    with:
      image-name: forumviriumhelsinki/my-app
      push: ${{ github.event_name != 'pull_request' }}

  security:
    uses: ForumViriumHelsinki/.github/.github/workflows/reusable-security-owasp.yml@main
    secrets:
      CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

## Community Health Files

Files at the root of this repo serve as org-wide defaults. Individual repos can override any of them by providing their own copy.

Files that **cannot** be org defaults (must be per-repo): `LICENSE`
