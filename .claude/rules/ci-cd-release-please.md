---
paths:
  - '**/.github/workflows/**'
---
# Release-Please Reusable Workflow

Part of the CI/CD rule set; the call conventions are in ci-cd-workflows.md.

### Release-Please Workflow Inputs

`reusable-release-please.yml` accepts these inputs:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `config-file` | string | `release-please-config.json` | Path to release-please config file |
| `manifest-file` | string | `.release-please-manifest.json` | Path to release-please manifest file |
| `app-id` | string | `''` | GitHub App **client ID** (a numeric App ID also works; the client ID is recommended). **Preferred**: when set, generates an App token via `APP_PRIVATE_KEY` instead of using the legacy `MY_RELEASE_PLEASE_TOKEN` PAT |
| `runner` | string | `ubuntu-slim` | Runner label — release-please is a pure GitHub-API job |
| `timeout-minutes` | number | `15` | Job timeout in minutes |
| `skip-on-release-commit` | boolean | `false` | **Leave unset.** Skips the job when the head commit starts with `chore(main): release` — which is the release PR's own merge commit, i.e. the run that cuts the tag and release. See the warning below |
| `missed-release-check` | string | `warn` | Guard against release-please silently considering zero commits. `warn` annotates, `error` fails the job, `off` disables |
| `releasable-types` | string | `feat,fix,perf,revert` | Comma-separated conventional-commit types the guard treats as release-worthy |
| `pr-assignees` | string | `''` | Comma-separated usernames to assign to the release PR, so it surfaces under `assignee:@me` in GitHub's dashboard and mobile feeds. Off when empty; literal usernames only (`@me` resolves to the App bot). A failed assignment warns, never fails the release |

### Do not set `skip-on-release-commit: true`

It does not prevent a cascade; it prevents releases. The reusable workflow gates the whole
job on it:

```yaml
# reusable-release-please.yml
if: >-
  inputs.skip-on-release-commit != true ||
  !startsWith(github.event.head_commit.message, 'chore(main): release')
```

release-please needs **two** runs to ship a version: one on a normal commit to open the
release PR, and one on that PR's **merge commit** to create the tag and the GitHub release.
The merge commit's message is `chore(main): release <version>`, so the flag skips exactly the
second run.

The failure is silent. The release PR merges green, `pyproject.toml` and
`.release-please-manifest.json` land on `main` with the new version, and there is no tag, no
GitHub release, and therefore no container image — `container-release.yml` triggers on
`release: published`, which never fires. The repo looks released.

> Observed 2026-08-25 (`fvh-data-pipe`, its first release): PR #38 merged as `b10c96df`, the
> release-please run on that commit reported **`skipped`**, `git ls-remote --tags` was empty,
> and the PR sat on `autorelease: pending`. Fixed in fvh-data-pipe#41 by removing the flag.

**Recovery needs no manual tagging.** release-please creates releases for merged PRs still
labelled `autorelease: pending`, so removing the flag and pushing any commit whose message
does not start with `chore(main): release` makes the next run pick up the stranded release PR.

**Verify a release by the artifact, not the workflow badge:**

```
gh api orgs/<org>/packages/container/<repo>/versions --jq '[.[].metadata.container.tags[]]'
```

A 403 there means a missing `read:packages` scope, not a missing image — control it against a
repo you know publishes before reading it as absence.

Secrets:
- `APP_PRIVATE_KEY` — GitHub App private key. Required when `app-id` is set. **Preferred — this is the org standard.**
- `MY_RELEASE_PLEASE_TOKEN` — legacy PAT with `contents:write` and `pull-requests:write` scopes. Used only when `app-id` is empty. The shared org PAT expired 2026-06; new and migrated repos must use the App token.

Outputs:
- `release_created` — `true` when this run created a release for the root component; empty otherwise, never `false`, because the action sets it only when a root release exists. Gate on `== 'true'`, not `!= 'false'`. Path components of a monorepo config are not forwarded.
- `tag_name` — tag of the root component's release from this run; empty when no root release was created, including when only path components were released.
- `missed_release` — `true` when the pushed range held releasable commits but release-please produced neither a release PR nor a release; `false` when it held none. Empty in every other case: on non-`push` events, with `missed-release-check: off`, when a release or release PR was created, and when the guard runs but skips without a verdict (a branch-creation push, an empty `releasable-types`, or a push range the compare API cannot resolve). Empty means not checked, so only `false` is a clean result.

A caller reads them through `needs.<job>.outputs`. podio-mcp gates its npm publish job on the release; its full caller is the example under **npm Publish Workflow Inputs** in ci-cd-packages.md:

```yaml
publish:
  needs: release-please
  if: ${{ needs.release-please.outputs.release_created == 'true' }}
```

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
