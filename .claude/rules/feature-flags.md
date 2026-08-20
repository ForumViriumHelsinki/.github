---
paths:
  - '**/deploy/values.yaml'
  - '**/deploy/**'
  - '**/src/**'
  - '**/.github/workflows/**'
---
# Feature Flags — GOFF + OpenFeature for Application Repos

## Rule: Prefer GoFeatureFlag over environment variables for feature toggles

When toggling features, conditional behavior, A/B testing, gradual rollouts, or kill switches — **always use GoFeatureFlag (GOFF) + OpenFeature SDK** rather than `ENABLE_*` / `FEATURE_*` environment variables or ConfigMap booleans.

**Use GOFF when the toggle needs any of**: per-user targeting, percentage rollouts, instant rollback without redeploy, A/B testing, scheduled activation, or frequent changes.

**Env vars remain correct for**: infrastructure config (DB URLs, ports), deploy-time settings (log level), secrets, and values that are identical for all users and only change at deploy time.

The `/feature-flags` skill provides a full decision framework. Reference `docs/FEATURE_FLAGS.md` in the infrastructure repo for the onboarding guide.

## Enabling GOFF in an Application

### 1. `deploy/values.yaml`

```yaml
featureFlags:
  enabled: true  # Injects GOFF relay proxy endpoint automatically

env:
  - name: GOFF_CLIENT_ID
    valueFrom:
      secretKeyRef:
        name: my-app-secrets
        key: GOFF_CLIENT_ID
```

Setting `featureFlags.enabled: true` in `helm-webapp` values automatically injects the `GOFEATUREFLAG_ENDPOINT` environment variable pointing to the internal relay proxy.

### 2. ExternalSecret for the evaluation key

```yaml
externalSecret:
  enabled: true
  name: my-app-secrets
  data:
    - secretKey: GOFF_CLIENT_ID
      remoteRef:
        key: my-app-goff_client_id  # Provisioned in infrastructure repo
```

### 3. OpenFeature SDK (application code)

Install the provider from PyPI as `gofeatureflag-python-provider` (there is no `openfeature-provider-go-feature-flag` package), then configure it with the endpoint and evaluation key from the injected env vars:

```python
import os
from openfeature import api
from gofeatureflag_python_provider.provider import GoFeatureFlagProvider
from gofeatureflag_python_provider.options import GoFeatureFlagOptions

api.set_provider(GoFeatureFlagProvider(
    options=GoFeatureFlagOptions(
        endpoint=os.environ.get("GOFEATUREFLAG_ENDPOINT"),
        api_key=os.environ.get("GOFF_CLIENT_ID"),
    )
))
```

`GoFeatureFlagProvider` takes a single `options=` argument — passing `endpoint=` / `api_key=` as direct keyword arguments raises a pydantic validation error. The provider handles `X-API-Key` header injection automatically.

## Evaluation Key Provisioning

Each application gets a **dedicated evaluation key** for independent revocation. Provisioning requires infrastructure repo changes (Terraform + ExternalSecret aggregation).

**To request a key**: open an issue in the infrastructure repo referencing `@infrastructure/.claude/rules/feature-flags.md` for the provisioning checklist.

Keys propagate via:
```
GCP Secret Manager → External Secrets Operator → K8s Secret → GOFF relay proxy
```

New keys take up to **1 hour** to propagate (ExternalSecret refresh interval).

## Key Principles

- **Never use env vars for runtime feature toggles** — use GOFF flags instead
- **Never hardcode evaluation keys** — always via ExternalSecret from GCP Secret Manager
- **One key per app** — enables independent revocation
- **Client-side evaluation** (browser extensions, etc.) passes the key directly via `X-API-Key`
