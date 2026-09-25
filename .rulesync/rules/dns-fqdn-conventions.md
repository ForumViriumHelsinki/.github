---
root: false
targets: ["claudecode", "copilot", "antigravity-ide", "cursor"]
description: "Trailing-dot FQDNs for hostnames pods resolve; bare hostnames where HTTP Host headers are matched"
globs: ["**/deploy/**", "**/k8s/**", "**/helm/**", "**/*.tf"]
---
# DNS FQDN Conventions

## Rule: trailing dot where the pod resolves the name, bare hostname where HTTP matches it

Kubernetes pods resolve with `ndots:5` and several search domains, so a name with fewer than five dots is tried against every search domain before the real lookup: for `redis.example.com`, first `redis.example.com.default.svc.cluster.local`, then the other search domains, and only then `redis.example.com.`. That is 5–12 wasted queries (A and AAAA per attempt). A trailing dot marks the name as absolute and skips them.

| Context | How the name is used | Form |
|---------|----------------------|------|
| Env vars, database hosts, connection strings, proxy upstreams | Resolved by the pod | `redis.example.com.` |
| Ingress `host:`, HTTPRoute `hostname:`, Gateway listener `hostname:` | Compared byte-for-byte with the HTTP `Host` header | `app.example.com` |
| DNS record values (`rrdatas` of a CNAME) | DNS protocol | `target.example.com.` |
| URLs (`https://api.example.com/path`) | Parsed by the HTTP client | no trailing dot |

Clients never send a trailing dot in `Host`, so an HTTPRoute or Ingress hostname with one never matches a request.

```yaml
env:
  REDIS_HOST: "redis.internal.example.com."   # resolved by the pod
gateway:
  hosts:
    - host: myapp.example.com                  # matched against Host
```
