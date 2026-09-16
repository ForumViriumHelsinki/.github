# Contributing

Thank you for your interest in contributing to Forum Virium Helsinki projects.

## Getting Started

1. Check the repository's `README.md` for project-specific setup instructions
2. Look for issues labeled `good first issue` or `help wanted`
3. Open an issue before starting large changes to discuss the approach

## Development Workflow

1. If you have write access (Forum Virium Helsinki staff), create a feature branch in the repository itself. Otherwise, fork the repository and branch from `main`
2. Make your changes following the project's coding conventions
3. Write or update tests as appropriate
4. Ensure all tests pass and linting is clean
5. Open a pull request against `main`

## Commit Messages

We use [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): short description

Optional longer description.

Refs #123
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `perf`

Breaking changes: add `!` after the type or include `BREAKING CHANGE:` in the footer.

Organization members: CI/CD is built from the [reusable workflows in this repository](https://github.com/ForumViriumHelsinki/.github#reusable-workflows); internal developer docs are linked from the members-only view of the [organization page](https://github.com/ForumViriumHelsinki).

## Pull Requests

- Keep PRs focused on a single change
- Reference related issues in the PR description
- Respond to review feedback promptly
- Squash fixup commits before merge

## Code Review and Merging

Default branches are protected by two rulesets: an organization baseline that blocks branch deletion and force-push, and a per-repository ruleset managed in Terraform that requires changes to land through a pull request and keeps history linear. Merges are squash or rebase only — merge commits are disabled in the repository settings.

Approving reviews are not enforced by those rulesets: the Terraform module default is `required_approving_review_count = 0` and no repository overrides it, and no CODEOWNERS file assigns a reviewer automatically. The Claude-powered review workflows are not required status checks and do not submit approving reviews. Required status checks are configured per repository.

## Reporting Issues

Use the issue templates provided in each repository. Include:
- Clear description of the problem or request
- Steps to reproduce (for bugs)
- Expected vs actual behavior
- Relevant environment details

## Questions

For questions about a specific project, open an issue in that repository. For general questions about Forum Virium Helsinki development, contact info@forumvirium.fi.
