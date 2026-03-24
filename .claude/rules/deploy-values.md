---
paths:
  - '**/deploy/values.yaml'
  - '**/deploy/**'
---
# Deploy Values Configuration

## Rule: Application repos own deployment config in `deploy/values.yaml` using the `helm-webapp` chart

The `helm-webapp` chart (`ghcr.io/forumviriumhelsinki/helm-webapp`) provides production-ready defaults. Most apps only need image coordinates — the chart handles ingress, service, probes, service account, and reloader automatically.

## Minimal Configuration

```yaml
image:
  repository: ghcr.io/forumviriumhelsinki/my-app
  tag: latest  # Managed by ArgoCD Image Updater — never edit manually
```

The chart auto-generates ingress at `{release-name}.dataportal.fi` with TLS. Override only when needed.

## Common Configuration Patterns

### Image Pull Secrets

```yaml
imagePullSecrets:
  - name: ghcr-login-secret
```

### Service Account with Workload Identity

```yaml
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: my-app@fvh-project.iam.gserviceaccount.com
```

### Cloud SQL Proxy Sidecar

```yaml
initContainers:
  - name: cloud-sql-proxy
    image: gcr.io/cloud-sql-connectors/cloud-sql-proxy:2
    restartPolicy: Always
    args:
      - "--structured-logs"
      - "--auto-iam-authn"
      - "fvh-project:europe-north1:fvh-postgres"
    securityContext:
      runAsNonRoot: true
```

### Environment Variables

```yaml
env:
  - name: APP_ENV
    value: "production"
  - name: DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: my-app-secrets
        key: DATABASE_URL
```

### External Secrets (GCP Secret Manager)

```yaml
externalSecret:
  enabled: true
  name: my-app-secrets
  secretStoreRef:
    kind: ClusterSecretStore
    name: gcp-store
  target:
    name: my-app-secrets
    creationPolicy: Owner
  data:
    - secretKey: DATABASE_URL
      remoteRef:
        key: my-app-database-url
```

Note: ExternalSecret declarations may also be managed via infrastructure-controlled `valuesObject` in the ArgoCD Application manifest. Check with the infrastructure repo for your app's pattern.

### Ingress (nginx class, cert-manager)

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: my-app.dataportal.fi
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: my-app-tls
      hosts:
        - my-app.dataportal.fi
```

### Gateway API (Envoy — preferred for new apps)

```yaml
gateway:
  enabled: true
  hosts:
    - host: my-app.dataportal.fi
      paths:
        - path: /
          pathType: PathPrefix
```

Gateway hostnames must match a listener in the infrastructure repo's `gateway.yaml`. See `@infrastructure/.claude/rules/helm-webapp-chart.md` for hostname constraints.

### KEDA Office-Hours Scaling

```yaml
keda:
  enabled: true
  triggers:
    - type: cron
      metadata:
        timezone: Europe/Helsinki
        start: "0 7 * * 1-5"
        end: "0 19 * * 1-5"
        desiredReplicas: "2"
  minReplicaCount: 0
  maxReplicaCount: 3
```

### Security Context and Read-Only Filesystem

```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL

volumes:
  - name: tmp
    emptyDir: {}
volumeMounts:
  - name: tmp
    mountPath: /tmp
```

### Resource Requests and Limits

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    memory: 256Mi
```

### Database Migrations (Helm Hook)

```yaml
migrations:
  enabled: true
  command: ["python", "manage.py", "migrate"]
```

## Image Tag Management

`image.tag` is automatically updated by ArgoCD Image Updater. **Never edit it manually.** The update flow:

1. Merge to `main` → GitHub Actions builds image → pushes to GHCR
2. Image Updater detects new tag → commits update to `deploy/values.yaml`
3. ArgoCD syncs the change → deploys new image

## Hostname Conventions

- **Ingress/Gateway `host:` fields**: Bare hostnames (`app.dataportal.fi`) — matched byte-for-byte against HTTP `Host` header
- **Env vars referencing external services**: Trailing-dot FQDNs (`redis.example.com.`) — skips K8s search-domain expansion

## References

- Full chart capabilities: `@infrastructure/.claude/rules/helm-webapp-chart.md`
- Multi-source deployment pattern: `@infrastructure/.claude/rules/argocd-values-ownership.md`
- DNS conventions: `@infrastructure/.claude/rules/dns-fqdn-conventions.md`
