---
root: false
targets: ["claudecode", "copilot", "antigravity-ide", "cursor"]
description: "A check must not share the state that would make it fail — inducing outages on Kubernetes, and self-checks that share a key"
globs: ["**/test/**", "**/tests/**", "**/*.test.*", "**/*.spec.*", "**/*_test.*", "**/test_*.py", "**/k8s/**", "**/deploy/**"]
---
# A Verification That Cannot Fail

## Rule: the check and its subject must not share the state that would make the check fail

A verifier that inherits its subject's input, key or reconciliation loop reports success whatever the subject does. Before writing an acceptance criterion or test, ask what the check shares with the thing it checks.

## Inducing an outage on Kubernetes

"Point the Deployment at a bad image tag and re-run the probe" usually probes a **healthy** app:

- **Rounding keeps the old pod.** With `replicas: 1`, the default rolling update rounds `maxUnavailable: 25%` down to 0. The bad pod is surged alongside the healthy one, which never leaves the Service.
- **GitOps undoes the break.** ArgoCD `selfHeal` reverts a patched spec as drift, typically within a minute.

What works: **delete the pod.** A deletion is not drift, so nothing reverts it, and the Service has no ready endpoint until the replacement is ready. Sample the control and the probe in the same command, so each result carries proof the subject was down:

```sh
kubectl -n <ns> get endpointslice -l kubernetes.io/service-name=<svc> -o jsonpath='{range .items[*].endpoints[*]}{.conditions.ready}{"\n"}{end}' | grep -c true
```

Trust a probe result only in a sample where the ready count is `0`. Also say which layer answered: an OAuth filter can redirect an unauthenticated request before it reaches the dead backend, so a 302 says nothing about the backend.

## Self-checks that sign and verify with one key

A signing or minting path that verifies its own output with the same secret proves the **encoding** round-trips, not that the consumer holds that secret. A wrong but consistent key passes every such check. Only the real consumer accepting the artifact proves agreement. If the test environment cannot reach it, say so and name the guard that bounds the failure; do not write a criterion for a symptom the code cannot produce.
