#!/usr/bin/env bash
# Discovery runner for this repo's workflow tests.
#
# Runs every .github/tests/<name>/run.sh in sorted order from the repo root,
# prints one line per test, and replays a failing test's output indented under
# its FAIL line. Exits 1 if any test fails, and also if no test is found: an
# empty run is green by construction and asserts nothing.
#
# Usage: bash .github/tests/run.sh [name ...]   # no names = every test
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

tests=""
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    if [ ! -f ".github/tests/$name/run.sh" ]; then
      echo "ERROR: no test named '$name' (expected .github/tests/$name/run.sh)" >&2
      exit 1
    fi
    tests="$tests.github/tests/$name/run.sh
"
  done
else
  shopt -s nullglob
  for t in .github/tests/*/run.sh; do
    tests="$tests$t
"
  done
  shopt -u nullglob
  tests="$(printf '%s' "$tests" | LC_ALL=C sort)"
fi

if [ -z "$tests" ]; then
  echo "ERROR: discovered zero tests under .github/tests/*/run.sh; refusing to report a vacuous pass" >&2
  exit 1
fi

total=0
failed=0
failed_names=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  name="$(basename "$(dirname "$t")")"
  total=$((total + 1))
  if out="$(bash "$t" 2>&1)"; then
    printf 'PASS  %s  %s\n' "$name" "$(printf '%s\n' "$out" | tail -n 1)"
  else
    rc=$?
    failed=$((failed + 1))
    failed_names="$failed_names $name"
    printf 'FAIL  %s  (exit %s)\n' "$name" "$rc"
    printf '%s\n' "$out" | sed 's/^/    | /'
  fi
done <<EOF
$tests
EOF

if [ "$failed" -gt 0 ]; then
  echo "$failed of $total test(s) failed:$failed_names"
  exit 1
fi
echo "All $total test(s) passed."
