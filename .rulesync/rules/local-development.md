---
root: false
targets: ["claudecode", "copilot", "geminicli", "cursor"]
description: "Local dev patterns — Skaffold profiles, justfile recipes, pre-commit hooks"
globs: ["**/skaffold.yaml", "**/justfile", "**/k8s/**", "**/.pre-commit-config.yaml"]
---
# Local Development Patterns

## Skaffold Profiles

Applications use Skaffold for local Kubernetes development with common profiles:

| Profile | Purpose |
|---------|---------|
| `dev` | Full stack (all services + databases) |
| `db-only` | Database only (for running app server locally) |
| `services-only` | Infrastructure services without the main app |
| `frontend-only` | Frontend dev server with hot reload |

Local dev uses plain K8s manifests in `k8s/` — not Helm. Production uses `helm-webapp` from GHCR.

## K8s Prerequisites

- **OrbStack** (recommended) or Docker Desktop for local Kubernetes
- OrbStack provides LoadBalancer support via `*.k8s.orb.local` — no port-forward needed

## Justfile Standard Recipe Groups

Application justfiles should organize recipes into these groups:

| Group | Recipes |
|-------|---------|
| dev | `dev`, `dev-db`, `dev-services`, `logs`, `shell` |
| test | `test`, `test-watch`, `test-coverage` |
| lint | `lint`, `format`, `typecheck` |
| build | `build`, `docker-build` |
| database | `db-migrate`, `db-seed`, `db-reset`, `db-shell` |

## Pre-commit Hooks

Common hooks across FVH application repos:

| Hook | Purpose |
|------|---------|
| `commitizen` | Enforce conventional commit messages |
| `biome` / `ruff` | Language-specific linting and formatting |
| `detect-secrets` | Prevent accidental secret commits |
| `check-yaml` / `trailing-whitespace` | General file hygiene |
| `helm-lint` | Validate Helm values (if `deploy/` exists) |

Install and run:

```bash
pre-commit install
pre-commit run --all-files
```

## Local ↔ CI Parity

**Aspiration, not a hard rule.** When adding or changing a quality gate (linter, formatter, type check, test tier), prefer configurations where the local command and the CI step run the same checks. This prevents the "passes locally, fails in CI" footgun.

Concrete patterns that help:

- A `just lint` / `just test` recipe that invokes the *same* command as the corresponding CI step (e.g. `ruff check` **and** `ruff format --check`, not just one).
- Pre-commit hooks mirror the CI lint/format jobs so `pre-commit run --all-files` catches what CI would catch.
- When CI adds a new check, update the matching local recipe in the same PR.

**Known-acceptable deviations:** full parity isn't always feasible — heavy Playwright suites, integration tests requiring external services, or long-running security scans may be CI-only. When diverging intentionally:

- Note it in the recipe comment or the job, so the next person understands the gap
- Prefer a lighter local variant (e.g. `just test-unit` locally, full suite in CI) over nothing
- Track "fix properly" work as an issue when the divergence is a temporary workaround (e.g. runner capacity), not a permanent design choice

Don't enforce parity strictly during reviews — surface the gap, suggest a lighter local equivalent, and move on.
