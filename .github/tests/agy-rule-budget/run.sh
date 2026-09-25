#!/usr/bin/env bash
# Generated Antigravity rules stay inside agy's size limits.
#
# Antigravity rejects a rule file over its per-file limit, and all loaded rules
# share one rules budget of about 20,000 tokens. Limits enforced here, in bytes:
#
#   PER_FILE_MAX     24,000  every .agents/rules/*.md (the per-file limit)
#   ALWAYS_ON_MAX     8,192  sum of `trigger: always_on` rules, which load in
#                            every session whatever file is open
#   TOTAL_MAX        64,000  sum of all rules: the worst case, where every glob
#                            matches, stays under 20,000 tokens at the ~3.2
#                            bytes per token of this Markdown
#
# A rule that outgrows PER_FILE_MAX is split by topic, as ci-cd-workflows.md
# was (ci-cd-release-please.md, ci-cd-claude.md, ci-cd-packages.md).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PER_FILE_MAX=24000
ALWAYS_ON_MAX=8192
TOTAL_MAX=64000

shopt -s nullglob
files=(.agents/rules/*.md)
[ "${#files[@]}" -gt 0 ] || { echo "FAIL: agy-rule-budget: no .agents/rules/*.md files"; exit 1; }

assertions=0
total=0
always_on=0
fail=0
for f in "${files[@]}"; do
  size=$(wc -c <"$f" | tr -d ' ')
  total=$((total + size))
  if grep -Eq '^trigger:[[:space:]]*always_on[[:space:]]*$' "$f"; then
    always_on=$((always_on + size))
  fi
  assertions=$((assertions + 1))
  if [ "$size" -ge "$PER_FILE_MAX" ]; then
    echo "FAIL: agy-rule-budget: $f is $size bytes (limit $PER_FILE_MAX); split it by topic"
    fail=1
  fi
done

assertions=$((assertions + 1))
if [ "$always_on" -ge "$ALWAYS_ON_MAX" ]; then
  echo "FAIL: agy-rule-budget: always_on rules total $always_on bytes (limit $ALWAYS_ON_MAX)"
  fail=1
fi
assertions=$((assertions + 1))
if [ "$total" -ge "$TOTAL_MAX" ]; then
  echo "FAIL: agy-rule-budget: all rules total $total bytes (limit $TOTAL_MAX)"
  fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "PASS: agy-rule-budget ($assertions assertion(s); ${#files[@]} files, $total bytes, always_on $always_on bytes)"
