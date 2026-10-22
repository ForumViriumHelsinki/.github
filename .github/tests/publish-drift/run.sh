#!/usr/bin/env bash
# Every workflow that runs claude-code-action with --json-schema must carry
# the shared publish block, byte-identical bar its masked env values
# (scripts/check-publish-drift.sh). Fails on drift and on absence: a workflow
# with the schema and no block discards its findings (issue #115).
#
# The drift check compares copies within this repo only, so it cannot see the
# block drift from its laurigates/.github source. The stale-wording check
# below pins the comment edits ported from there (laurigates/.github#79): a
# copy reintroducing one of these phrases is the old, wrong wording coming
# back, and identity within this repo would not catch it if all eight did.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The expected count is the number of reusable workflows that pass
# --json-schema today. A new analysis workflow raises it here on purpose.
EXPECTED=8

assertions=0
status=0

if ! out="$(bash scripts/check-publish-drift.sh "$EXPECTED" 2>&1)"; then
  printf '%s\n' "$out"
  status=1
else
  printf '%s\n' "$out"
fi
assertions=$((assertions + 1))

# Each pattern is an ERE for wording that is false in this repo:
# - a bare `#47` names an unrelated FVH issue; upstream's is
#   laurigates/.github#47, written in full (the pattern requires a non-word,
#   non-dot character before the `#`, so the full form does not match);
# - "only produced denials": the action grants no comment tool, so there was
#   nothing to deny;
# - "~10 annotations" / "Unverified exact figure": the limit is documented
#   (10 per level per step, 50 per job);
# - "drift check compares ... laurigates/.github": the drift check compares
#   copies within this repo, never with laurigates/.github.
stale=(
  '(^|[^[:alnum:]_.])#47([^0-9]|$)'
  'only produced denials'
  '~10 annotations'
  'Unverified[[:space:]]*$'
  'drift check compares'
  'byte-for-byte with laurigates/\.github'
)
checked=0
for f in .github/workflows/reusable-*.yml; do
  grep -q -- '--json-schema' "$f" || continue
  checked=$((checked + 1))
  for re in "${stale[@]}"; do
    assertions=$((assertions + 1))
    if hits="$(grep -nE -- "$re" "$f")"; then
      printf 'STALE wording /%s/ in %s:\n%s\n' "$re" "$f" "$hits"
      status=1
    fi
  done
done
assertions=$((assertions + 1))
if [ "$checked" -ne "$EXPECTED" ]; then
  printf 'stale-wording check visited %d workflow(s), expected %d\n' "$checked" "$EXPECTED"
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo "FAIL: publish-drift"
  exit 1
fi
echo "PASS: publish-drift (${assertions} assertion(s))"
