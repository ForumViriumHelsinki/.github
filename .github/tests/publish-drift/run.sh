#!/usr/bin/env bash
# Every workflow that runs claude-code-action with --json-schema must carry
# the shared publish block, byte-identical bar its masked env values
# (scripts/check-publish-drift.sh). Fails on drift and on absence: a workflow
# with the schema and no block discards its findings (issue #115).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The expected count is the number of reusable workflows that pass
# --json-schema today. A new analysis workflow raises it here on purpose.
EXPECTED=8

if ! out="$(bash scripts/check-publish-drift.sh "$EXPECTED" 2>&1)"; then
  printf '%s\n' "$out"
  echo "FAIL: publish-drift"
  exit 1
fi
printf '%s\n' "$out"
echo "PASS: publish-drift (1 assertion(s))"
