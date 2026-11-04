#!/usr/bin/env bash
# The rule files recommend the secret scanner the org actually runs (gitleaks,
# via reusable-gitleaks.yml and this repo's pre-commit hook), never
# detect-secrets (issue #188). The control checks that every hook id in this
# repo's .pre-commit-config.yaml is listed in the source rule's hook table.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

assertions=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Every rule source and generated copy that consumers receive.
mapfile -t files < <(git ls-files .rulesync/rules .claude/rules .agents/rules .cursor/rules .github/instructions)
[ "${#files[@]}" -gt 0 ] || fail "git ls-files found no rule files"
assertions=$((assertions + 1))

if hits=$(grep -n -- 'detect-secrets' "${files[@]}"); then
  fail "rule files recommend detect-secrets; the org standard is gitleaks:
$hits"
fi
assertions=$((assertions + 1))

# Control: the hooks this repo runs appear in the Pre-commit Hooks table.
source_rule=.rulesync/rules/local-development.md
table=$(awk '/^## Pre-commit Hooks/ {in_section = 1; next} /^## / {in_section = 0} in_section && /^\|/' "$source_rule")
[ -n "$table" ] || fail "no Pre-commit Hooks table found in $source_rule"
assertions=$((assertions + 1))

mapfile -t hook_ids < <(yq -r '.repos[].hooks[].id' .pre-commit-config.yaml)
[ "${#hook_ids[@]}" -gt 0 ] || fail "yq found no hook ids in .pre-commit-config.yaml"
assertions=$((assertions + 1))

for id in "${hook_ids[@]}"; do
  grep -Fq "\`$id\`" <<<"$table" || fail "hook '$id' from .pre-commit-config.yaml is missing from the Pre-commit Hooks table in $source_rule"
  assertions=$((assertions + 1))
done

echo "PASS: secret-scanner-rules (${assertions} assertion(s))"
