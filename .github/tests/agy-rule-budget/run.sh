#!/usr/bin/env bash
# Generated Antigravity rules stay inside agy's size limits.
#
# The limits, from https://antigravity.google/docs/rules?tab=ide
# ("Size limits and token budgets"), enforced here in bytes:
#
#   PER_FILE_MAX     24,000  every .agents/rules/*.md. Antigravity truncates
#                            a rule file over 24,000 bytes.
#   ALWAYS_ON_MAX     8,192  sum of `trigger: always_on` rules, which load in
#                            every session whatever file is open. They share
#                            the 20,000-token budget for active global and
#                            always_on rules with the user's own global rules.
#
# There is no limit on the total of all rules (#202). The 20,000-token budget
# covers active global and always_on rules, and the docs do not say a matched
# glob rule counts. Over it, Antigravity demotes the largest rule files to
# pointers that the agent reads on demand, so nothing fails to load. The total
# is printed on success so its growth stays visible.
#
# A rule that outgrows PER_FILE_MAX is split by topic, as ci-cd-workflows.md
# was (ci-cd-release-please.md, ci-cd-claude.md, ci-cd-packages.md).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PER_FILE_MAX=24000
ALWAYS_ON_MAX=8192

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

[ "$fail" -eq 0 ] || exit 1
echo "PASS: agy-rule-budget ($assertions assertion(s); ${#files[@]} files, $total bytes, always_on $always_on bytes)"
