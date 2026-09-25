# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is the ForumViriumHelsinki `.github` special repository — the org-wide hub for reusable GitHub Actions workflows, community health files, issue/PR templates, and workflow starter templates. All FVH application repos call these reusable workflows rather than implementing CI/CD logic inline.

## Architecture

### Directory Layout

- `.github/workflows/reusable-*.yml` — 23 reusable workflows callable via `uses: ForumViriumHelsinki/.github/.github/workflows/<name>.yml@main`
- `.github/workflows/lint.yml`, `.github/tests/`, `justfile` — this repo's own lint gate and workflow tests (see [Testing Workflows](#testing-workflows))
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
- `reusable-npm-publish.yml` — Publishes an npm package via OIDC trusted publishing (no `NPM_TOKEN`); npm version pinned, build-time env passed as `KEY=VALUE` blocks
- `reusable-bun-ci.yml` — Pull-request gate for bun/TypeScript repos: frozen-lockfile install, then the repo's own typecheck (opt-in), test and build commands; optional coverage artifact; no secrets

**Claude-powered (all use `anthropics/claude-code-action@v1`):**
- `reusable-claude.yml` — @-mention support in issues/PRs
- `reusable-claude-review.yml` — Automated PR reviews
- `reusable-auto-fix.yml` — Analyzes workflow failures, auto-fixes or creates issues
- `reusable-enforce-conventional-commits.yml` — Auto-fixes PR titles
- Security: `reusable-security-{secrets,deps,owasp}.yml`
- Quality: `reusable-quality-{code-smell,async,typescript}.yml`
- Accessibility: `reusable-a11y-{aria,wcag}.yml`

The eight Security/Quality/Accessibility workflows pass `--json-schema` and default to `model: haiku` and `max-budget-usd: 5` (0 is unbounded, which lets a retry loop run on). They publish findings to the **job summary and PR file annotations**, never a PR comment: the action is granted no GitHub write tool, so the old "Leave a PR comment" prompt discarded every finding (#115). Both channels work under the `contents: read` the jobs already hold.

Four things not to re-derive:
- **The publish block is byte-identical across all eight and with `laurigates/.github`**, bar four env values (`TITLE`, `BLOCKING_SEVERITIES`, `COUNT_KEYS`, `NOTHING_SCANNED_REASON`, masked by the drift check). It is duplicated on purpose: `uses:` takes no expressions, so a shared composite action would run at floating `@main` even for a caller pinned by SHA, and a script in this repo is not checked out (these jobs check out the *caller*). `scripts/check-publish-drift.sh` fails on absence as well as drift. FVH-only additions go outside the `BEGIN`/`END` markers so future `[SYNC]` PRs stay mechanical.
- **The analysis step runs with `continue-on-error: true`, and `Classify analysis outcome` decides the job.** The action fails the step whenever `--json-schema` is set and an otherwise successful run returns no `structured_output`, which happens non-deterministically. The verdict step reads Claude's final `result` message from the action's `execution_file` output (written before that check, and set on the failure path): `subtype: success` with `is_error: false` and no structured output is a warning and a green job; anything else that failed the step is an error with the reason. Guards downstream read `steps.analyze.outcome`, which stays `failure` under `continue-on-error`; `conclusion` would read `success`.
- **Every gate predicate compares numerically** (`steps.publish.outputs.blocking > 0`), never as a string (`!= '0'`), and none carries `always()`. GitHub coerces the empty string a skipped publish step leaves to 0 for `>`, so a numeric gate cannot fire on a PR that scanned nothing.
- **Everything the model emits is untrusted at the shell boundary.** It crosses into `run:` only through `env:`; annotation payloads (`severity` included) are `%`/CR/LF-escaped; `line` and the counts are type-checked, because a count carrying a newline writes a second `key=value` line into `$GITHUB_OUTPUT` and can overwrite `blocking`. The fixture harnesses extract the shipped step bodies rather than holding retyped copies.

### Build-Once/Promote Pattern

The container workflows use a two-phase pattern to avoid redundant rebuilds:

1. **PR phase** (`container-build`): Reads version from `package.json` (configurable), builds and pushes `:next-{version}` image to GHCR
2. **Release phase** (`container-release`): On tag push, looks up `:next-{version}` image and does a manifest-only retag to semver tags (seconds, not minutes). Falls back to full rebuild if pre-release image is missing. The semver tags derive from the version left after stripping `tag-prefix`, so a `tag-prefix` that does not prefix the release tag fails the run. `.github/tests/container-release-tags/run.sh` pins this.

Release images are signed with cosign keyless (Sigstore OIDC) and scanned with Trivy.

### Key Design Constraints

- **No GitHub Code Security (GHAS)**: The FVH org doesn't have it. Never use `github/codeql-action/upload-sarif` or `security-events: write` in workflows — they'll 403 on private repos. Use Trivy standalone without SARIF upload.
- **Action pinning**: All third-party actions are pinned to full SHA with a version comment (e.g., `actions/checkout@<sha> # v6.0.2`). Renovate manages these pins.
- **Concurrency groups**: Claude-powered workflows use `cancel-in-progress: false` to avoid interrupting AI analysis.
- **Auto-fix loop prevention**: The auto-fix workflow skips if a recent `fix(auto):` commit exists on the branch.
- **`additional_permissions` is a permissions map, not a tool list**: `anthropics/claude-code-action` reads it as `key: value` lines (`actions: read`) for its App token and skips any line without a colon, so a Claude tool list there is silently inert. Tools go in an `allowed_tools` input composed into `claude_args` as `--allowedTools "..."` (repeated `--allowedTools` flags accumulate). The `github_ci` MCP server checks the job's `GITHUB_TOKEN`, so a workflow that runs in tag mode (`track_progress: true`, or no `prompt`) needs `actions: read` in its `permissions:` block; `additional_permissions` cannot substitute. `.github/tests/claude-action-permissions/run.sh` checks both rules.

## Conventions

- **Conventional commits** required (`feat:`, `fix:`, `docs:`, `ci:`, etc.) — release-please uses these for version bumps
- **Workflow naming**: `reusable-{category}-{name}.yml` for reusable workflows; category prefixes group related workflows
- **Workflow templates**: Each template in `workflow-templates/` needs both a `.yml` file and a matching `.properties.json` with name, description, iconName, and categories
- Community health files at repo root serve as org-wide defaults; individual repos override by providing their own copy

### Shared AI Coding Rules

Organization-wide coding rules for AI assistants are maintained in `.rulesync/rules/`. These are the canonical source — `rulesync generate` produces tool-specific files for Claude Code (`.claude/rules/`), Antigravity (`.agents/rules/`, rulesync target `antigravity-ide`), GitHub Copilot (`.github/instructions/`), and Cursor (`.cursor/rules/`).

Application repos pull these rules via the `reusable-sync-ai-rules.yml` workflow, which uses `rulesync fetch` + `rulesync generate` and creates a PR with updates.

To regenerate locally after editing rules:

```bash
npx rulesync@latest generate
```

To validate generated files are in sync (CI):

```bash
npx rulesync@latest generate --check
```

Edit `.rulesync/rules/*.md` directly, then run `generate` and `generate --check`, and commit the source change and its regenerated copies in one commit. `.rulesync/.aiignore` deliberately does not list `.rulesync/` or `rulesync.jsonc`: every line there becomes a `Read(...)` deny in `.claude/settings.json`, which also blocks Edit, Write and path-naming Bash commands, and Claude Code auto-loads only CLAUDE.md files, `.claude/rules/` and `@` imports ([memory docs](https://code.claude.com/docs/en/memory)), so the sources are never loaded twice. Generation replaces every `Read(...)` deny in `.claude/settings.json` with the `.aiignore` set, so add ignore patterns to `.aiignore`, not to `settings.json`.

## Testing Workflows

`.github/workflows/lint.yml` gates every PR and push to `main`. Run the same checks locally before pushing:

```bash
just lint                     # yq YAML check + actionlint -shellcheck= + gitleaks dir + rulesync generate --check
just test                     # every .github/tests/<name>/run.sh, via .github/tests/run.sh
just test workflow-contract   # one test by name
```

Tests live in `.github/tests/<name>/run.sh` and follow the convention in `.github/tests/README.md`: bash with `set -euo pipefail`, run from the repo root, extract the shipped text out of the workflow file rather than retyping it, stub CLIs with a sentinel, scan every `reusable-*.yml` for the defect class, and prove the test fails on the pre-fix tree before opening the PR. The discovery runner fails when it finds zero tests.

Behaviour that only a real run shows is still validated by pointing a calling repo's `@main` at a feature branch temporarily, or with a workflow dispatch, and by reading the run logs after merge.

The Claude analysis workflows have four tests of their own: `publish-drift` (wraps `scripts/check-publish-drift.sh 8`), `publish-findings` and `analysis-verdict`, which run fixtures against the step bodies extracted from every workflow that passes `--json-schema`, and `analysis-contract`, which checks the same workflows' schema (`findings` required), prompt (no "Leave a PR comment"), job outputs and numeric union gates.
