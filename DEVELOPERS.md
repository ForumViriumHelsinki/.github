# Developing at Forum Virium Helsinki

A short orientation for someone joining Forum Virium Helsinki as a developer, or working with us on code. Everything linked here is public; the internal documentation is linked at the end and opens once you are a member of the GitHub organization.

## What we build

Smart-city services for the City of Helsinki: IoT and sensor data platforms, mobility and traffic data services, environmental monitoring, and open data APIs. Most of our code is open source and lives in this organization.

## How we work

- **Everything is in Git.** Application code, Kubernetes configuration, and cloud infrastructure. Changes reach production by merging a pull request, not by editing a server.
- **GitOps deployment.** ArgoCD watches the repositories and applies what is in Git. Applications are packaged with Helm; the cluster is GKE Autopilot on Google Cloud.
- **Infrastructure as code.** Terraform manages Google Cloud, GitHub, identity and network access.
- **Conventional commits** drive automated versioning and releases (release-please). Dependency updates come from Renovate.
- **Shared CI/CD.** Repositories call the reusable workflows in this repository rather than copying pipeline YAML. The same repository holds the coding rules our AI assistants follow.

If you have worked on a VM you SSH into and edit in place, the change is real: you will edit locally, commit, and let the pipeline deploy. It takes a few days to get used to, and it is what makes rollbacks, review and reproducibility possible.

## Read these before you have any accounts

- [CONTRIBUTING.md](CONTRIBUTING.md) — branching, commit format, pull requests, review and merge norms
- [SECURITY.md](SECURITY.md) — how to report a vulnerability (never in a public issue)
- [SUPPORT.md](SUPPORT.md) — where to ask for help
- [Reusable workflows](README.md#reusable-workflows) — the CI/CD building blocks every repository uses
- [Development workflow overview](https://forumviriumhelsinki.github.io/dev-workflow-overview/) — how a change travels from commit to production
- [forumviriumhelsinki.fi](https://forumviriumhelsinki.fi) and [Helsinki Region Infoshare](https://hri.fi) — what the organization does, and the open data behind much of it

## Accounts you will need

Access is requested for you during onboarding; several of these are still granted by hand, so ask if something is missing after your first week.

| Account | Used for |
|---|---|
| Google Workspace | Mail, calendar, Chat, Drive; also the sign-in for several tools below |
| GitHub organization | This organization's private repositories and the infrastructure wiki |
| OneLogin | Single sign-on for internal services |
| Twingate | Zero-trust network access to internal resources |
| Google Cloud | Cloud console and Kubernetes cluster access, scoped to what your work needs |
| ArgoCD | Deployment dashboard; permissions are granted per project |
| Sentry | Application error tracking |
| Podio | Project and ticket workspaces |
| Silverbucket | Working-hour reporting and project resourcing |
| eFina | Expense claims and payroll matters |

## Once you are in the organization

- **Infrastructure wiki** — setup guides, platform architecture, and how-tos: `github.com/ForumViriumHelsinki/infrastructure/wiki`
- **Members-only organization profile** — the link hub for the above, visible on the organization page when signed in
- **`sites`** — a monorepo for static sites and demos, where one directory becomes one published site

Both the infrastructure repository and its wiki are private, so those links return "not found" until your GitHub account is a member.

## Getting help

Open an issue in the relevant repository. Inside the organization, the infrastructure repository has issue templates for questions, incidents and access requests, and the ICT and Google Cloud Chat spaces are where platform questions get answered. For anything security-related, follow [SECURITY.md](SECURITY.md) instead of filing an issue.
