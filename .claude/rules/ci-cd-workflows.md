---
paths:
  - '**/.github/workflows/**'
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
| `renovate.yml` | `reusable-renovate.yml` | Schedule | `GITHUB_TOKEN` or `app-id` + `APP_PRIVATE_KEY` |
| `container-build.yml` | `reusable-container-build.yml` | release-please PR (PR phase) | — |
| `container-release.yml` | `reusable-container-release.yml` | Published release (release phase) | — |
| `auto-merge-image-updater.yml` | `reusable-auto-merge-image-updater.yml` | `image-updater-**` branches | `AUTO_MERGE_PAT` or `app-id` + `APP_PRIVATE_KEY` |
| `claude.yml` | `reusable-claude.yml` | Issue/PR @-mentions | `CLAUDE_CODE_OAUTH_TOKEN` |

### Release-Please Workflow Inputs

`reusable-release-please.yml` accepts these inputs:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `config-file` | string | `release-please-config.json` | Path to release-please config file |
| `manifest-file` | string | `.release-please-manifest.json` | Path to release-please manifest file |
| `app-id` | string | `''` | GitHub App ID (**preferred**); when set, uses an App token instead of the legacy `MY_RELEASE_PLEASE_TOKEN` PAT |
| `runner` | string | `ubuntu-slim` | Runner label — release-please is a pure GitHub-API job |
| `timeout-minutes` | number | `15` | Job timeout in minutes |
| `skip-on-release-commit` | boolean | `false` | Skip when the head commit starts with `chore(main): release` to prevent cascading releases |
| `missed-release-check` | string | `warn` | Guard against release-please silently considering zero commits. `warn` annotates, `error` fails the job, `off` disables |
| `releasable-types` | string | `feat,fix,perf,revert` | Comma-separated conventional-commit types the guard treats as release-worthy |

Secrets:
- `APP_PRIVATE_KEY` — GitHub App private key. Required when `app-id` is set. **Preferred — this is the org standard.**
- `MY_RELEASE_PLEASE_TOKEN` — legacy PAT with `contents:write` and `pull-requests:write` scopes. Used only when `app-id` is empty. The shared org PAT expired 2026-06; new and migrated repos must use the App token.

Example — App-token caller (recommended; default for all repos):

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-release-please.yml@main
with:
  app-id: ${{ vars.CI_APP_ID }}
secrets:
  APP_PRIVATE_KEY: ${{ secrets.CI_APP_PRIVATE_KEY }}
```

Example — PAT caller (legacy; the shared org PAT expired 2026-06 — migrate to the App token above):

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
| `claude_args` | string | `''` | Additional CLI arguments (appended after built-in `--max-turns` and `--system-prompt`) |

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

### npm Publish Workflow Inputs

`reusable-npm-publish.yml` publishes an npm package via OIDC trusted publishing — no `NPM_TOKEN`. The caller's job must grant `id-token: write` and `contents: read`, and the package's trusted publisher must be configured on npmjs.com.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `node-version` | string | `24` | Node.js version for setup-node |
| `npm-version` | string | `11.16.0` | Exact npm version installed before publishing. Pinned, not `latest` — see below |
| `use-bun` | boolean | `true` | Set up Bun for bun-based install/build |
| `install-command` | string | `bun install --frozen-lockfile` | Dependency install command |
| `build-command` | string | `bun run build` | Build command (empty string to skip) |
| `build-env` | string | `''` | Newline-separated `KEY=VALUE` pairs exported to the install and build steps |
| `package-access` | string | `public` | Value for `npm publish --access` |
| `working-directory` | string | `.` | Directory containing the package to publish |
| `runner` | string | `ubuntu-latest` | Runner label |
| `timeout-minutes` | number | `15` | Job timeout in minutes |

Secrets:
- `secret-build-env` — additional newline-separated `KEY=VALUE` pairs exported to the install and build steps, whose values are secrets. Values are masked in logs. Use for credentials a `build` or `postbuild` script reads.

**Why `npm-version` is pinned.** Trusted publishing requires npm >= 11.5.1, so an explicit install is needed. It is pinned rather than `latest` because provenance behaviour changes between npm releases — 11.17.0 auto-attests without `--provenance`, and npm does not support provenance for private source repositories. The default `11.16.0` is the version the org's npm publisher currently runs. Public-repo callers that want auto-provenance override the input.

**Why build environment is passed as `KEY=VALUE` blocks.** Packages whose `build` or `postbuild` scripts read environment variables (e.g. to bake defaults into compiled output) have no other channel — the build step is a generic `run:`. The input/secret split mirrors `build-args` / `secret-build-args` in `reusable-container-build.yml`.

Example — caller with a release-please gate:

```yaml
jobs:
  release-please:
    uses: ForumViriumHelsinki/.github/.github/workflows/reusable-release-please.yml@main
    with:
      app-id: ${{ vars.CI_APP_ID }}
    secrets:
      APP_PRIVATE_KEY: ${{ secrets.CI_APP_PRIVATE_KEY }}

  publish:
    needs: release-please
    if: ${{ needs.release-please.outputs.release_created == 'true' }}
    permissions:
      contents: read
      id-token: write
    uses: ForumViriumHelsinki/.github/.github/workflows/reusable-npm-publish.yml@main
    with:
      node-version: '24'
    secrets:
      secret-build-env: |
        MY_CLIENT_ID=${{ secrets.MY_CLIENT_ID }}
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
- Missing standard workflows for a deployed application (release-please, renovate, container build/release, image-updater auto-merge, claude).
- Pinned `@<sha>` / `@v1` references to reusable workflows — confirm they are intentional vs. drift from `@main`.

Surface findings in the response — do not silently rewrite unrelated workflow files. Migration to reusable workflows is a deliberate change. Workspace-wide adoption status is also visible via `just fvh::workflow-matrix` from the workspace root.

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
