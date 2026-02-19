# Security Policy

## Supported Versions

We apply security patches to the latest release of each project. Older versions are not actively maintained.

## Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Report security vulnerabilities by email to **info@forumvirium.fi** with the subject line `[SECURITY] <repository name>`.

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Any suggested remediation

We will acknowledge receipt within 3 business days and aim to provide an initial assessment within 7 business days.

## Disclosure Policy

We follow coordinated disclosure. Please allow us reasonable time to investigate and patch before public disclosure. We will credit reporters in release notes unless anonymity is requested.

## Security Practices

- Dependencies are monitored for vulnerabilities via Renovate and GitHub Dependabot
- Container images are scanned with Trivy on every build
- Secrets are managed via Google Secret Manager; never committed to source
- All production deployments go through GitOps review via ArgoCD
