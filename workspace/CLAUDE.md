# Forum Virium Helsinki — Developer Guide for AI Assistants

Context for working on Forum Virium Helsinki (FVH) repositories, for a workspace
directory that holds a clone of `ForumViriumHelsinki/.github` and one or more other
FVH clones. `just workspace-rules`, run from that clone, adds
`@.github/workspace/CLAUDE.md` to the workspace's `CLAUDE.md`, so this file stays
current with `git -C .github pull`. Edit it in `ForumViriumHelsinki/.github`, not in
a workspace.

Several paths below are in `ForumViriumHelsinki/infrastructure`, which is private:
FVH developers can open them, others cannot.

## Repository Types

### Infrastructure (`ForumViriumHelsinki/infrastructure`, private)

The platform repo. Application developers rarely edit it, but deployments are
defined here:

- **ArgoCD Application manifests** in `argocd/apps/templates/<project>/` ("App of Apps")
- **AppProject definitions** (RBAC, allowed source repos) in `argocd/projects/`
- **Terraform** for GCP, GitHub (repos, labels, teams), Twingate, OneLogin, Sentry
- **Shared Helm chart** `helm/webapp`, published as `ghcr.io/forumviriumhelsinki/helm-webapp`

### Shared configuration (`ForumViriumHelsinki/.github`, public)

- **Reusable GitHub Actions workflows**: application repos call these instead of
  writing their own build/release pipelines.
- **AI coding rules**: canonical source in
  [`.rulesync/rules/`](https://github.com/ForumViriumHelsinki/.github/tree/main/.rulesync/rules),
  synced into application repos by `reusable-sync-ai-rules.yml`. Edit rules there,
  not in the synced copies.

### Application repositories

Everything else. Each one follows the same layout:

- Application source (frontend and/or backend) plus a `Dockerfile`
- `deploy/values.yaml`: Helm values for production
- `k8s/`: plain manifests for local development
- `skaffold.yaml`: local Kubernetes dev loop
- `.github/workflows/`: thin callers of the org reusable workflows

Detailed conventions live in the rules directory linked above:

| Rule | Covers |
|------|--------|
| `application-structure.md` | Required files, directory layout, Dockerfile patterns |
| `deploy-values.md` | `deploy/values.yaml` for the webapp chart |
| `ci-cd-workflows.md` | Calling the reusable workflows |
| `local-development.md` | Skaffold, justfile, pre-commit |
| `dependency-automation.md` | Renovate, release-please, ArgoCD Image Updater |
| `feature-flags.md` | GoFeatureFlag + OpenFeature SDK |

## Deployment Architecture

### Who owns what

| Concern | Infrastructure repo | Application repo |
|---------|:-------------------:|:----------------:|
| ArgoCD Application manifest | ✓ | |
| AppProject definition | ✓ | |
| Shared Helm chart | ✓ | |
| Helm values (`deploy/values.yaml`) | | ✓ |
| Container image build | | ✓ |
| Image tag (written automatically) | | ✓ |
| ExternalSecret declarations | | ✓ |
| Local K8s manifests (`k8s/`) | | ✓ |
| Skaffold config | | ✓ |
| CI/CD workflows | | ✓ |

### Multi-source ArgoCD applications

Each ArgoCD Application combines two sources:

1. The **Helm chart** from GHCR (usually `helm-webapp`), referenced by the
   manifest in the infrastructure repo.
2. The **values file** `deploy/values.yaml` from the application repo.

The platform side controls deployment mechanics; the application side controls its
own configuration. A change to either triggers an ArgoCD sync.

### Image updates are automatic

CI builds and pushes the image to GHCR. ArgoCD Image Updater then writes the new
tag back into the app's `deploy/values.yaml`. **Never edit `image.tag` by hand.**

### Secrets

1. **Google Secret Manager** holds every secret (source of truth).
2. **External Secrets Operator** syncs them into Kubernetes.
3. Pods consume them as environment variables.

To add a secret: create it in Secret Manager, then declare it in the app's Helm
values. Never commit secret values.

## Local Development

Each application repo owns its local setup. Production uses the shared Helm chart;
local development uses the plain manifests in `k8s/` (local databases, mocked
services) driven by `skaffold.yaml` profiles such as `dev` and `db-only`. If the
repo has a `justfile`, prefer its recipes (`just --list`) over calling tools
directly.

## Common Tasks

### Adding a new application

1. **Application repo**: code, `Dockerfile`, and a workflow calling the org
   reusable container-build workflow.
2. **Application repo**: `deploy/values.yaml`.
3. **Infrastructure repo**: ArgoCD Application manifest in `argocd/apps/templates/`.
4. **Infrastructure repo**: add the app to its AppProject in `argocd/projects/`.
5. **Infrastructure repo**: Image Updater annotations on the Application.

### Changing deployment configuration

| Change | Where |
|--------|-------|
| Replicas, env vars, resources, ingress, secrets list | `deploy/values.yaml` in the app repo |
| Sync policy, sources, ArgoCD behaviour | Manifest in the infrastructure repo |
| Image version | Nothing to do: Image Updater handles it |
| New secret value | GCP Secret Manager, then declare in values |

### Debugging a deployment

1. ArgoCD UI: sync status and errors for the Application.
2. The Application manifest in `infrastructure/argocd/apps/templates/`.
3. The app's `deploy/values.yaml`.
4. AppProject permissions in `infrastructure/argocd/projects/`.
5. ExternalSecret status, for anything secret-related.

## Technology Stack

| Layer | Technology |
|-------|------------|
| Cloud | Google Cloud Platform (GKE Autopilot) |
| GitOps | ArgoCD with Image Updater |
| IaC | Terraform (Terraform Cloud workspaces) |
| Registry | GitHub Container Registry (GHCR) |
| Secrets | Google Secret Manager + External Secrets Operator |
| CI/CD | GitHub Actions (org reusable workflows) |
| Policy | Kyverno |
| Feature flags | GoFeatureFlag relay proxy + OpenFeature SDK |
| Ingress | Envoy Gateway (preferred), Ingress NGINX (legacy) |
| Error tracking | Sentry |

## Constraints and Conventions

- **No GitHub Advanced Security.** The org does not have GitHub Code Security, so
  CodeQL, SARIF upload, and `security-events: write` fail with 403 on private
  repos. Omit those steps entirely; don't wrap them in `continue-on-error`. Use
  Dependabot alerts, Trivy scans that report to the log or a PR comment, and
  secret push protection instead.
- **Conventional commits** (`feat:`, `fix:`, `chore:` …). release-please derives
  versions and changelogs from them, so PR titles must follow the format too.
- **Everything goes through git.** Deployment changes land as commits; ArgoCD
  deploys from the repos.
- **GitHub settings are Terraform-managed.** Repo settings, labels, and archiving
  live in `infrastructure/github/`; changes made in the GitHub UI get reverted on
  the next apply.
- **Test locally first** with Skaffold before pushing.
- **Sequence cross-repo changes**: land the application-side change and the
  infrastructure-side change in an order that never leaves a broken deploy.
