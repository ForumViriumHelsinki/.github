# Local Development Patterns

## Skaffold Profiles

Applications use Skaffold for local Kubernetes development with common profiles:

| Profile         | Purpose                                        |
| --------------- | ---------------------------------------------- |
| `dev`           | Full stack (all services + databases)          |
| `db-only`       | Database only (for running app server locally) |
| `services-only` | Infrastructure services without the main app   |
| `frontend-only` | Frontend dev server with hot reload            |

Local dev uses plain K8s manifests in `k8s/` — not Helm. Production uses `helm-webapp` from GHCR.

## K8s Prerequisites

- **OrbStack** (recommended) or Docker Desktop for local Kubernetes
- OrbStack provides LoadBalancer support via `*.k8s.orb.local` — no port-forward needed

## Justfile Standard Recipe Groups

Application justfiles should organize recipes into these groups:

| Group    | Recipes                                          |
| -------- | ------------------------------------------------ |
| dev      | `dev`, `dev-db`, `dev-services`, `logs`, `shell` |
| test     | `test`, `test-watch`, `test-coverage`            |
| lint     | `lint`, `format`, `typecheck`                    |
| build    | `build`, `docker-build`                          |
| database | `db-migrate`, `db-seed`, `db-reset`, `db-shell`  |

## Pre-commit Hooks

Common hooks across FVH application repos:

| Hook                                 | Purpose                                    |
| ------------------------------------ | ------------------------------------------ |
| `commitizen`                         | Enforce conventional commit messages       |
| `biome` / `ruff`                     | Language-specific linting and formatting   |
| `detect-secrets`                     | Prevent accidental secret commits          |
| `check-yaml` / `trailing-whitespace` | General file hygiene                       |
| `helm-lint`                          | Validate Helm values (if `deploy/` exists) |

Install and run:

```bash
pre-commit install
pre-commit run --all-files
```

## Pre-commit Config Gotchas

A red `pre-commit` / "Code Quality" CI job often traces to the hook _config_,
not the code. These three hit FVH app repos and are config fixes, not file edits:

| Symptom                                                                   | Root cause                                                                                                                                                                                                        | Fix                                                                                                                                                                                                    |
| ------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| biome: `Found a nested root configuration`                                | A subdir config (e.g. `react_ui/biome.json`) run with `--config-path` from the repo root is treated as a second root config under biome 2.x                                                                       | Add `"root": false` to the nested config **and** drop `--config-path` from the hook `entry` so biome auto-discovers per file (the two are mutually exclusive — `--config-path` requires a root config) |
| yamllint: `wrong indentation: expected N but found N-2` on every sequence | Helm/k8s values align block sequences with their parent key; the default `indent-sequences: true` rejects that style                                                                                              | Set `indentation: {indent-sequences: consistent}` in `.yamllint` — workflows indent, values don't; both stay internally consistent                                                                     |
| check-yaml: `Failed` on a `deploy/*values.yaml`                           | A **duplicate top-level key** (ruamel rejects dup keys). YAML last-wins silently dropped the first block — e.g. a second `migrations:` overriding the first's `migrations.image` that ArgoCD Image Updater tracks | Merge the duplicated key's blocks into one, preserving the path Image Updater writes to (`migrations.image.tag`)                                                                                       |

When the fix is on the hook config, also bump any `additional_dependencies`
version pin to match the config's `$schema` (e.g. biome `2.3.14`), and verify
with `pre-commit run <hook-id> --all-files` before pushing.

## Local ↔ CI Parity

**Aspiration, not a hard rule.** When adding or changing a quality gate (linter, formatter, type check, test tier), prefer configurations where the local command and the CI step run the same checks. This prevents the "passes locally, fails in CI" footgun.

Concrete patterns that help:

- A `just lint` / `just test` recipe that invokes the _same_ command as the corresponding CI step (e.g. `ruff check` **and** `ruff format --check`, not just one).
- Pre-commit hooks mirror the CI lint/format jobs so `pre-commit run --all-files` catches what CI would catch.
- When CI adds a new check, update the matching local recipe in the same PR.

**Known-acceptable deviations:** full parity isn't always feasible — heavy Playwright suites, integration tests requiring external services, or long-running security scans may be CI-only. When diverging intentionally:

- Note it in the recipe comment or the job, so the next person understands the gap
- Prefer a lighter local variant (e.g. `just test-unit` locally, full suite in CI) over nothing
- Track "fix properly" work as an issue when the divergence is a temporary workaround (e.g. runner capacity), not a permanent design choice

Don't enforce parity strictly during reviews — surface the gap, suggest a lighter local equivalent, and move on.
