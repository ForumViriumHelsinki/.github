---
trigger: glob
globs: '**/*.template,**/nginx/**,**/Dockerfile*'
---
# nginx `envsubst` Templates: No `${VAR}` in Comments

## Rule: never write `${VAR}` inside an nginx comment in a template

The stock `nginx` image renders `/etc/nginx/templates/*.template` into `/etc/nginx/conf.d/` with `envsubst` at container start. `envsubst` rewrites the whole file, **comments included**, and an nginx `#` comment ends at a newline. If a comment contains `${VAR}` and the value ends in `\n`, the words after the newline become a directive and nginx refuses to start:

```
nginx: [emerg] unknown directive "<word>" in /etc/nginx/conf.d/default.conf:<line>
```

The container crash-loops, the Service has no endpoints, and the gateway returns `upstream connect error ... Connection refused`. A running pod keeps its old environment, so the failure appears only on the next restart, possibly days after the bad value landed.

Name the variable in prose in comments (`API_KEY`, not `${API_KEY}`). Directives that need the value (`set`, `rewrite`, `proxy_set_header`) end at `;` and are not affected.

## Where the newline comes from

A secret set with `echo` or `uuidgen |` carries a trailing `\n`. Set values with `printf '%s'`:

```sh
printf '%s' "$VALUE" | gcloud secrets versions add <secret> --data-file=-
```

A value one byte longer than expected (37 bytes for a 36-character UUID) is the tell.

## Restoring a crashed pod

1. `kubectl logs <pod> -c <container>` shows the `[emerg]` line.
2. Rewrite the secret without the newline. Command substitution strips trailing newlines and keeps internal ones, so PEM values survive:
   ```sh
   printf '%s' "$(gcloud secrets versions access latest --secret=<secret>)" | gcloud secrets versions add <secret> --data-file=-
   ```
3. Force the ExternalSecret to resync, then restart the Deployment. The resync alone does not change a running pod's environment.

If the hostname sits behind an OAuth gate, an unauthenticated `curl` gets the IdP redirect and looks healthy. Judge backend health from endpoints and pod status instead.
