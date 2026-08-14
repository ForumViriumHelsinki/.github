---
root: false
targets: ["claudecode", "copilot", "geminicli", "cursor"]
description: "Runtime GitHub API access via a GitHub App installation"
globs: ["**/deploy/values.yaml", "**/deploy/**", "**/src/**"]
---
# Runtime GitHub API Access — Use a GitHub App, Mint Tokens In-Process

## Rule: a deployed app that calls the GitHub API authenticates as a GitHub App installation, minting the installation token inside the process

This covers **runtime** access — an app creating an issue, commenting on a PR,
or pushing a file while serving a request. GitHub Actions workflows are a
separate case and use `actions/create-github-app-token`; see
`ci-cd-workflows.md`.

Two shapes to avoid:

| Shape | Why not |
|---|---|
| **PAT in a secret** (`GITHUB_TOKEN`) | Tied to a human account, carries that account's reach rather than a scoped installation, manual rotation |
| **Pre-minted installation token in a secret** | Installation tokens expire after **60 minutes**; ExternalSecret `refreshInterval` is `1h`, so the delivered token is frequently already dead |

Store the App **private key** instead — long-lived, so the refresh interval
stops mattering — and let the pod derive short-lived tokens from it.

## Shape

Three env vars, delivered by ExternalSecret from Google Secret Manager:

```yaml
env:
  GITHUB_APP_ID:               # the App's client ID
  GITHUB_APP_INSTALLATION_ID:
  GITHUB_APP_PRIVATE_KEY:      # PEM
```

TypeScript — `@octokit/auth-app` handles caching and refresh:

```ts
new Octokit({ authStrategy: createAppAuth, auth: { appId, privateKey, installationId } })
```

Python — RS256 JWT (`iss` = the App's **client ID**, which GitHub's JWT docs
recommend over the numeric App ID; `exp` ≤ 10 min) → `POST
/app/installations/{id}/access_tokens`, cached until shortly before
`expires_at`. Cache the client or the token, never mint per request.

## Reference implementation

thelma's report-issue feature runs this in-cluster today:

| Piece | Path |
|---|---|
| Secrets + IAM + populate instructions | `@infrastructure/gcp/thelma_github_app_secrets.tf` |
| ExternalSecret + env wiring | `thelma/deploy/values.yaml` (`GITHUB_APP_*`) |
| In-process minting | `thelma/src/lib/github/feedback-client.ts` |

Full procedure — Terraform triad, `gcloud secrets versions add` commands, apply
order, Python recipe, verification, traps:
`@infrastructure/.claude/skills/github-app-runtime-auth/SKILL.md`.

## Two gotchas worth carrying here

- **Apply order.** The `infrastructure-gcp` TFC apply must land *before* the
  `deploy/values.yaml` change. A `remoteRef` pointing at a secret that does not
  exist yet leaves the ExternalSecret unable to sync and the pod without the
  keys.
- **Fail closed, and loudly.** Check all three env vars up front and disable the
  feature explicitly (503, or a logged skip) rather than throwing mid-request.
  Where GitHub errors are deliberately swallowed so they cannot block the
  primary path, add a metric or alert — otherwise a permanently 403'ing
  credential is indistinguishable from a working one.
