#!/usr/bin/env bash
# Contract test for what this repo ships to other FVH repos.
#
#   1. Every .github/workflows/reusable-*.yml is callable (`on` includes
#      workflow_call) and declares a top-level `permissions:` map, so a caller
#      never hands it more token scope than it asked for.
#   2. Every workflow-templates/<name>.yml has a <name>.properties.json that
#      parses and carries the two keys GitHub requires (name, description),
#      and no metadata file is orphaned.
#   3. Every `uses: ForumViriumHelsinki/.github/.github/workflows/<file>@<ref>`
#      in a tracked file (workflows, templates, docs, generated rule copies)
#      names a workflow that exists here and declares workflow_call.
#
# Reads the shipped files directly with yq and python3 (both on ubuntu-slim).
# Every scan asserts it found something before its per-item checks, so an
# empty glob or a broken pattern fails instead of passing vacuously.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null 2>&1 || { echo "FATAL: yq not on PATH" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH" >&2; exit 1; }

assertions=0
failures=0

pass() { assertions=$((assertions + 1)); }
fail() { assertions=$((assertions + 1)); failures=$((failures + 1)); echo "FAIL: $*"; }

# `on` may be a string, a list, or a map; all three forms are valid workflow
# syntax. yq converts it to JSON and python3 decides, which keeps the three
# cases readable.
is_callable() {
  yq -o=json '.on' "$1" 2>/dev/null | python3 -c '
import json, sys
on = json.load(sys.stdin)
ok = on == "workflow_call" if isinstance(on, str) else "workflow_call" in (on or [])
sys.exit(0 if ok else 1)'
}

shopt -s nullglob

# ------------------------------------------------------------ 1. reusables
reusables=(.github/workflows/reusable-*.yml)
if [ "${#reusables[@]}" -eq 0 ]; then
  fail "no .github/workflows/reusable-*.yml found (glob matched nothing)"
else
  pass
fi
for f in ${reusables[@]+"${reusables[@]}"}; do
  if is_callable "$f"; then pass; else fail "$f: \`on\` does not include workflow_call"; fi
  if [ "$(yq '.permissions | tag' "$f" 2>/dev/null)" = "!!map" ]; then
    pass
  else
    fail "$f: no top-level \`permissions:\` map"
  fi
done

# ------------------------------------------------------------ 2. templates
templates=(workflow-templates/*.yml)
if [ "${#templates[@]}" -eq 0 ]; then
  fail "no workflow-templates/*.yml found (glob matched nothing)"
else
  pass
fi
for f in ${templates[@]+"${templates[@]}"}; do
  meta="${f%.yml}.properties.json"
  if [ ! -f "$meta" ]; then
    fail "$f: missing $meta"
    continue
  fi
  if err="$(python3 - "$meta" 2>&1 <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if not isinstance(data, dict):
    sys.exit("top level is not an object")
for key in ("name", "description"):
    if not isinstance(data.get(key), str) or not data[key].strip():
        sys.exit(f"required key {key!r} missing or empty")
PY
  )"; then
    pass
  else
    fail "$meta: ${err##*$'\n'}"
  fi
done
for meta in workflow-templates/*.properties.json; do
  if [ -f "${meta%.properties.json}.yml" ]; then pass; else fail "$meta: no matching .yml template"; fi
done

# ------------------------------------------------------------ 3. uses: refs
# [A-Za-z0-9._-]+ excludes doc placeholders such as `<name>.yml`.
refs="$(git grep -hoE 'uses:[[:space:]]*ForumViriumHelsinki/\.github/\.github/workflows/[A-Za-z0-9._-]+@[A-Za-z0-9._/-]+' \
  | sed -E 's#.*/workflows/([^@]+)@.*#\1#' | LC_ALL=C sort -u || true)"
if [ -z "$refs" ]; then
  fail "found no 'uses: ForumViriumHelsinki/.github/.github/workflows/<file>@<ref>' references (pattern or git grep broken)"
else
  pass
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  target=".github/workflows/$name"
  if [ ! -f "$target" ]; then
    where="$(git grep -lE "workflows/${name//./\\.}@" | tr '\n' ' ' || true)"
    fail "uses: …/workflows/$name points at a file that does not exist (referenced in: $where)"
  elif ! is_callable "$target"; then
    fail "uses: …/workflows/$name points at a workflow that does not declare workflow_call"
  else
    pass
  fi
done <<EOF
$refs
EOF

if [ "$failures" -gt 0 ]; then
  echo "FAIL: workflow-contract ($failures of $assertions assertion(s) failed)"
  exit 1
fi
echo "PASS: workflow-contract ($assertions assertion(s))"
