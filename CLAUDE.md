# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is the ForumViriumHelsinki `.github` special repository — the org-wide hub for reusable GitHub Actions workflows, community health files, issue/PR templates, and workflow starter templates. All FVH application repos call these reusable workflows rather than implementing CI/CD logic inline.

## Architecture

### Directory Layout

- `.github/workflows/reusable-*.yml` — 19 reusable workflows callable via `uses: ForumViriumHelsinki/.github/.github/workflows/<name>.yml@main`
- `.github/ISSUE_TEMPLATE/` — org-default issue templates (bug report, feature request)
- `.github/PULL_REQUEST_TEMPLATE.md` — org-default PR template
- `workflow-templates/` — starter workflows shown in the GitHub Actions "New workflow" UI (each has a `.yml` + `.properties.json` pair)
- `profile/README.md` — org profile displayed on github.com/ForumViriumHelsinki
- `.rulesync/rules/*.md` — canonical AI coding rules for all FVH application repos (source of truth)
- `rulesync.jsonc` — rulesync configuration for generating tool-specific files
- Root community health files (`CODE_OF_CONDUCT.md`, `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`)

### Workflow Categories

**Infrastructure (container lifecycle + release automation):**
- `reusable-container-build.yml` — PR phase: builds `:next-{version}` pre-release image
- `reusable-container-release.yml` — Release phase: promotes pre-built image to semver tags + Trivy scan + cosign signing
- `reusable-release-please.yml` — Automated versioning and changelogs
- `reusable-auto-merge-image-updater.yml` — Auto-merges ArgoCD Image Updater PRs
- `reusable-fix-release-conflicts.yml` — Auto-resolves release-please merge conflicts
- `reusable-auto-resolve-conflicts.yml` — General conflict resolution
- `reusable-renovate.yml` — Dependency updates

**Claude-powered (all use `anthropics/claude-code-action@v1`):**
- `reusable-claude.yml` — @-mention support in issues/PRs
- `reusable-claude-review.yml` — Automated PR reviews
- `reusable-auto-fix.yml` — Analyzes workflow failures, auto-fixes or creates issues
- `reusable-enforce-conventional-commits.yml` — Auto-fixes PR titles
- Security: `reusable-security-{secrets,deps,owasp}.yml`
- Quality: `reusable-quality-{code-smell,async,typescript}.yml`
- Accessibility: `reusable-a11y-{aria,wcag}.yml`

### Build-Once/Promote Pattern

The container workflows use a two-phase pattern to avoid redundant rebuilds:

1. **PR phase** (`container-build`): Reads version from `package.json` (configurable), builds and pushes `:next-{version}` image to GHCR
2. **Release phase** (`container-release`): On tag push, looks up `:next-{version}` image and does a manifest-only retag to semver tags (seconds, not minutes). Falls back to full rebuild if pre-release image is missing.

Release images are signed with cosign keyless (Sigstore OIDC) and scanned with Trivy.

### Key Design Constraints

- **No GitHub Code Security (GHAS)**: The FVH org doesn't have it. Never use `github/codeql-action/upload-sarif` or `security-events: write` in workflows — they'll 403 on private repos. Use Trivy standalone without SARIF upload.
- **Action pinning**: All third-party actions are pinned to full SHA with a version comment (e.g., `actions/checkout@<sha> # v6.0.2`). Renovate manages these pins.
- **Concurrency groups**: Claude-powered workflows use `cancel-in-progress: false` to avoid interrupting AI analysis.
- **Auto-fix loop prevention**: The auto-fix workflow skips if a recent `fix(auto):` commit exists on the branch.

## Conventions

- **Conventional commits** required (`feat:`, `fix:`, `docs:`, `ci:`, etc.) — release-please uses these for version bumps
- **Workflow naming**: `reusable-{category}-{name}.yml` for reusable workflows; category prefixes group related workflows
- **Workflow templates**: Each template in `workflow-templates/` needs both a `.yml` file and a matching `.properties.json` with name, description, iconName, and categories
- Community health files at repo root serve as org-wide defaults; individual repos override by providing their own copy

### Shared AI Coding Rules

Organization-wide coding rules for AI assistants are maintained in `.rulesync/rules/`. These are the canonical source — `rulesync generate` produces tool-specific files for Claude Code (`.claude/rules/`), Antigravity CLI (`.agents/rules/`), GitHub Copilot (`.github/instructions/`), and Cursor (`.cursor/rules/`).

Application repos pull these rules via the `reusable-sync-ai-rules.yml` workflow, which uses `rulesync fetch` + `rulesync generate` and creates a PR with updates.

To regenerate locally after editing rules:

```bash
npx rulesync@latest generate
```

To validate generated files are in sync (CI):

```bash
npx rulesync@latest generate --check
```

## Testing Workflows

There is no local test suite. Workflow changes are validated by:

1. `actionlint` for static analysis of workflow syntax
2. Testing in a calling repo by pointing `@main` to a feature branch temporarily, or using a workflow dispatch
3. Reviewing GitHub Actions run logs after merge
