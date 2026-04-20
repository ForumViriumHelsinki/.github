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
| `release-please.yml` | `reusable-release-please.yml` | Push to `main` | `MY_RELEASE_PLEASE_TOKEN` (PAT) or `app-id` + `APP_PRIVATE_KEY` |
| `container-build.yml` | `reusable-container-build.yml` | release-please PR (PR phase) | — |
| `container-release.yml` | `reusable-container-release.yml` | Published release (release phase) | — |
| `auto-merge-image-updater.yml` | `reusable-auto-merge-image-updater.yml` | `image-updater-**` branches | `AUTO_MERGE_PAT` |
| `claude.yml` | `reusable-claude.yml` | Issue/PR @-mentions | `CLAUDE_CODE_OAUTH_TOKEN` |

### Release-Please Workflow Inputs

`reusable-release-please.yml` accepts these inputs:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `config-file` | string | `release-please-config.json` | Path to release-please config file |
| `manifest-file` | string | `.release-please-manifest.json` | Path to release-please manifest file |
| `app-id` | string | `''` | GitHub App ID; when set, uses an App token instead of `MY_RELEASE_PLEASE_TOKEN` |
| `runner` | string | `ubuntu-latest` | Runner label |
| `timeout-minutes` | number | `15` | Job timeout in minutes |
| `skip-on-release-commit` | boolean | `false` | Skip when the head commit starts with `chore(main): release` to prevent cascading releases |

Secrets:
- `MY_RELEASE_PLEASE_TOKEN` — PAT with `contents:write` and `pull-requests:write` scopes. Required when `app-id` is empty.
- `APP_PRIVATE_KEY` — GitHub App private key. Required when `app-id` is set.

Example — App-token caller (infrastructure repo):

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-release-please.yml@main
with:
  app-id: ${{ vars.RELEASE_PLEASE_APP_ID }}
secrets:
  APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

Example — PAT caller (existing repos, unchanged):

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-release-please.yml@main
secrets:
  MY_RELEASE_PLEASE_TOKEN: ${{ secrets.MY_RELEASE_PLEASE_TOKEN }}
```

### Renovate Workflow Inputs

`reusable-renovate.yml` accepts these inputs:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `config-file` | string | `renovate.json` | Path to renovate config file |
| `log-level` | string | `info` | Renovate log level |
| `dry-run` | string | `false` | Dry run mode (`false`, `full`, `lookup`) |
| `app-id` | string | `''` | Renovate GitHub App ID; when set, generates an App token instead of using `GITHUB_TOKEN` |
| `bot-username` | string | `''` | `RENOVATE_USERNAME` (e.g. `fvh-renovate-bot[bot]`). Only applies when `app-id` is set. |
| `bot-git-author` | string | `''` | `RENOVATE_GIT_AUTHOR` full author string. Only applies when `app-id` is set. |
| `timeout-minutes` | number | `60` | Job timeout in minutes |

Secrets:
- `APP_PRIVATE_KEY` — Renovate App private key. Required iff `app-id` is set.

Example — App-token caller (infrastructure repo):

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-renovate.yml@main
with:
  app-id: ${{ vars.RENOVATE_APP_ID }}
  bot-username: fvh-renovate-bot[bot]
  bot-git-author: fvh-renovate-bot <fvh-renovate-bot[bot]@users.noreply.github.com>
secrets:
  APP_PRIVATE_KEY: ${{ secrets.RENOVATE_APP_PRIVATE_KEY }}
```

### Claude Workflow Inputs

`reusable-claude.yml` accepts these inputs for per-repo customization:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `runner` | string | `ubuntu-slim` | Runner label |
| `max_turns` | number | `30` | Maximum agentic turns before stopping |
| `claude_args` | string | `''` | Additional CLI arguments. These are appended after built-in arguments. Avoid passing arguments like `--max-turns` that are handled by dedicated inputs to prevent conflicts. |

Example — increase turns for a large codebase:

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-claude.yml@main
with:
  max_turns: 50
secrets:
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### Max-Turns Handoff

When Claude exhausts its turn budget, the workflow posts a continuation comment instead of failing silently:

1. Detects `error_max_turns` from the execution output
2. Posts a comment with progress summary, branch name (if partial work was pushed), and a continuation prompt
3. User replies "Continue where you left off @claude" to trigger a new run with full conversation context
4. The bot filter (`sender.type != 'Bot'`) prevents infinite loops

The workflow also injects a `--system-prompt` instructing Claude to commit and push partial progress early for multi-step tasks.

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
