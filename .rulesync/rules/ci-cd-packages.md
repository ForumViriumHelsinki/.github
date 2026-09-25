---
root: false
targets: ["claudecode", "copilot", "antigravity-ide", "cursor"]
description: "Inputs of the reusable npm publish and bun CI workflows for TypeScript packages"
globs: ["**/.github/workflows/**"]
---
# Package Build and Publish Reusable Workflows

Part of the CI/CD rule set; the call conventions are in ci-cd-workflows.md.

### npm Publish Workflow Inputs

`reusable-npm-publish.yml` publishes an npm package via OIDC trusted publishing — no `NPM_TOKEN`. The caller's job must grant `id-token: write` and `contents: read`, and the package's trusted publisher must be configured on npmjs.com.

The trusted publisher entry names the **caller's** repository and workflow filename, not this reusable workflow — npm validates the calling workflow's name, not the one containing `npm publish` ([npm docs, Trusted publishers](https://docs.npmjs.com/trusted-publishers)). Migrating an existing inline publish job onto this workflow therefore needs no npmjs.com change, provided the caller workflow's filename stays the same.

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

Keys are validated before they reach `$GITHUB_ENV`. A line whose key is not a valid shell identifier is warned about and skipped; a key that is runner-reserved or able to change what later steps execute (`GITHUB_*`, `RUNNER_*`, `ACTIONS_*`, `PATH`, `NODE_OPTIONS`, `BASH_ENV`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, `NODE_AUTH_TOKEN`, `NPM_CONFIG_*`) fails the job. `$GITHUB_ENV` is job-scoped, so these values also reach the `prepublishOnly`/`prepare` rebuild that `npm publish` triggers — check what that does to your tarball before passing build secrets.

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

### Bun CI Workflow Inputs

`reusable-bun-ci.yml` is the pull-request gate for bun/TypeScript repos: install from `bun.lock`, then run the repository's own typecheck, test and build commands in one job. It takes no secrets and needs only `contents: read`.

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `install-command` | string | `bun install --frozen-lockfile` | Dependency install command. Bun does not enable `--frozen-lockfile` on its own in CI |
| `typecheck-command` | string | `''` | Type-check command, run after install (empty string to skip; opt-in) |
| `test-command` | string | `bun run test` | Test command (empty string to skip) |
| `build-command` | string | `bun run build` | Build command (empty string to skip) |
| `coverage` | boolean | `false` | Upload `<working-directory>/coverage/` as the `coverage` artifact (30-day retention; fails if the directory is empty) |
| `bun-version` | string | `''` | Bun version for `oven-sh/setup-bun`. Empty reads `packageManager`/`engines.bun` from the repository-root `package.json`, then falls back to latest |
| `node-version` | string | `''` | Node.js version for setup-node (empty string to skip Node setup) |
| `cache-dependencies` | boolean | `true` | Cache `~/.bun/install/cache` keyed on `<working-directory>/bun.lock` |
| `working-directory` | string | `.` | Directory containing `package.json` and `bun.lock` |
| `runner` | string | `ubuntu-latest` | Runner label |
| `timeout-minutes` | number | `15` | Job timeout in minutes |

Commands are read from `env:` and run through `eval`, so shell operators work — a pre-install step chains onto `install-command` (`bun install --frozen-lockfile && bun run db:generate`). `coverage: true` does not change the test command; point `test-command` at the script that writes `coverage/` (e.g. `bun run test:coverage`). Codecov upload stays in the caller.

**The build script is not necessarily the type gate.** Bundlers such as esbuild (WXT, Vite) strip type annotations without checking them, and plain `tsc --noEmit` can be red on arrival where a framework supplies ambient types through its own tsconfig — `silverbucket-helper` reported 201 errors, 149 of them chrome-namespace. `build-command` therefore defaults to the repo's own `bun run build`, and `typecheck-command` is opt-in. Set it to whatever the repo treats as its type gate.

**A production build may hard-fail without secrets.** A PR gate compiles the code; it does not assert that secrets exist — secret presence belongs in the release workflow. If the production build throws on missing credentials, build in development mode instead (`bunx wxt build --mode development`).

`bun-version` should be set explicitly for subdirectory projects: setup-bun's `package.json` fallback reads the repository root, not `working-directory`. Concurrency is set at job level with a `bun-ci-` group prefix; do not give the caller a concurrency group starting with `bun-ci-`, because a called workflow sees the caller's name in `github.workflow` and equal groups cancel the caller.

Example — the `silverbucket-helper` gate on the shared workflow:

```yaml
on:
  pull_request:
    branches: [main]

permissions:
  contents: read

jobs:
  bun-ci:
    uses: ForumViriumHelsinki/.github/.github/workflows/reusable-bun-ci.yml@main
    with:
      test-command: bun run test:coverage
      typecheck-command: bun run compile:gate
      build-command: bunx wxt build --mode development
      coverage: true
```
