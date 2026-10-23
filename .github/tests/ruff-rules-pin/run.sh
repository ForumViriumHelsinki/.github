#!/usr/bin/env bash
# ruff-rules-pin — `just lint` and lint.yml must both run the same pinned
# `ruff format --check` over the Python blocks in .rulesync/rules (#182).
#
# Consumers that run `ruff format --check` over their whole tree also format
# Python code blocks inside Markdown (ruff 0.16), so a rule snippet that is not
# in ruff style fails the consumer's sync PR (google-chat-agent#322, fixed in
# #176). Only the .rulesync/rules source is checked; `rulesync generate --check`
# already ties the generated copies to it.
#
# Asserts, on the shipped text (lint.yml via yq, the justfile via awk):
#   - lint.yml has the ruff step, before "Workflow tests", with no `if:` and no
#     `continue-on-error` (a step that can be skipped or ignored gates nothing);
#   - its RUFF_VERSION equals the justfile's ruff_version, and is X.Y.Z;
#   - its RUFF_SHA256 is 64 hex characters and is checked with `sha256sum -c`
#     against a download URL built from RUFF_VERSION;
#   - the CI step and the justfile run the same arguments,
#     `format --check --diff --isolated --line-length 88 .rulesync/rules`;
#   - the justfile runs ruff only through `uvx ruff@{{ ruff_version }}` or
#     `mise exec aqua:astral-sh/ruff@{{ ruff_version }}`, never a bare `ruff`
#     from PATH (any other version formats Markdown differently), and fails
#     when neither runner exists.
# Needs no ruff: the formatter itself is exercised by `just lint` and by CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=ruff-rules-pin
WORKFLOW=${1:-.github/workflows/lint.yml}
JUSTFILE=${2:-justfile}
STEP='ruff format (Python blocks in rule Markdown)'
ARGS='format --check --diff --isolated --line-length 88 .rulesync/rules'

command -v yq >/dev/null || { echo "FAIL: $NAME: yq not found on PATH"; exit 1; }

failures=0
assertions=0
check() { # check <message> <command...>: one assertion, the command must succeed
  local msg=$1
  shift
  assertions=$((assertions + 1))
  if ! "$@"; then
    echo "FAIL: $NAME: $msg"
    failures=$((failures + 1))
  fi
}
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
matches() { [[ $1 =~ $2 ]]; }
before() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }

# --- lint.yml -------------------------------------------------------------
export STEP
count=$(yq '[.jobs.lint.steps[] | select(.name == strenv(STEP))] | length' "$WORKFLOW")
check "$WORKFLOW: expected exactly one step named '$STEP', found $count" \
  test "$count" = 1
if [ "$count" != 1 ]; then
  echo "$failures failure(s)"
  exit 1
fi

idx=$(yq '.jobs.lint.steps | to_entries | .[] | select(.value.name == strenv(STEP)) | .key' "$WORKFLOW")
tests_idx=$(yq '.jobs.lint.steps | to_entries | .[] | select(.value.name == "Workflow tests") | .key' "$WORKFLOW")
check "$WORKFLOW: '$STEP' (index $idx) must come before 'Workflow tests' (index ${tests_idx:-missing})" \
  before "$idx" "$tests_idx"

has_if=$(yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | has("if")' "$WORKFLOW")
check "$WORKFLOW: '$STEP' has an if:, so it can be skipped" \
  test "$has_if" = false
has_coe=$(yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | has("continue-on-error")' "$WORKFLOW")
check "$WORKFLOW: '$STEP' has continue-on-error, so a failure is ignored" \
  test "$has_coe" = false

ci_version=$(yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .env.RUFF_VERSION // ""' "$WORKFLOW")
ci_sha=$(yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .env.RUFF_SHA256 // ""' "$WORKFLOW")
body=$(yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .run // ""' "$WORKFLOW")

check "$WORKFLOW: RUFF_VERSION '$ci_version' is not an exact X.Y.Z version" \
  matches "$ci_version" '^[0-9]+\.[0-9]+\.[0-9]+$'
check "$WORKFLOW: RUFF_SHA256 '$ci_sha' is not 64 lowercase hex characters" \
  matches "$ci_sha" '^[0-9a-f]{64}$'
# shellcheck disable=SC2016 # the literal ${...} text of the shipped step
check "$WORKFLOW: '$STEP' does not download the release named by \${RUFF_VERSION}" \
  contains "$body" 'releases/download/${RUFF_VERSION}/'
# shellcheck disable=SC2016
check "$WORKFLOW: '$STEP' does not verify the download with sha256sum -c against \${RUFF_SHA256}" \
  contains "$body" '"${RUFF_SHA256}  /tmp/ruff.tgz" | sha256sum -c -'
check "$WORKFLOW: '$STEP' does not run '/tmp/ruff $ARGS'" \
  contains "$body" "/tmp/ruff $ARGS"
check "$WORKFLOW: '$STEP' does not set -euo pipefail, so a failed download can fall through" \
  contains "$body" 'set -euo pipefail'

# --- justfile -------------------------------------------------------------
just_version=$(awk -F'"' '/^ruff_version[[:space:]]*:=/ { print $2; exit }' "$JUSTFILE")
check "$JUSTFILE: no ruff_version := \"X.Y.Z\" variable" \
  test -n "$just_version"
check "ruff versions differ: $WORKFLOW RUFF_VERSION '$ci_version' != $JUSTFILE ruff_version '$just_version'" \
  test "$just_version" = "$ci_version"

# The lint recipe: from `lint:` to the next unindented line.
recipe=$(awk '/^lint:/ { on = 1; next } on && /^[^[:space:]#]/ { exit } on { print }' "$JUSTFILE")
check "$JUSTFILE: no lint recipe found" \
  test -n "$recipe"

uvx_line=$(grep -F 'uvx "ruff@{{ ruff_version }}"' <<<"$recipe" || true)
mise_line=$(grep -F 'mise exec "aqua:astral-sh/ruff@{{ ruff_version }}" -- ruff' <<<"$recipe" || true)
check "$JUSTFILE lint: no uvx \"ruff@{{ ruff_version }}\" runner" \
  test -n "$uvx_line"
check "$JUSTFILE lint: no mise exec \"aqua:astral-sh/ruff@{{ ruff_version }}\" runner" \
  test -n "$mise_line"

# Every line that runs a ruff formatter must go through a pinned runner and
# carry the CI arguments (directly or via the runner array the recipe runs).
runs=$(grep -E '(^|[[:space:]"(])ruff([[:space:]")]|$)' <<<"$recipe" | grep -vE '^[[:space:]]*#' | grep -v 'not found' || true)
bare=$(grep -vE 'uvx "ruff@\{\{ ruff_version \}\}"|mise exec "aqua:astral-sh/ruff@\{\{ ruff_version \}\}"' <<<"$runs" || true)
check "$JUSTFILE lint: ruff run outside a pinned runner (a bare ruff on PATH may be another version): $bare" \
  test -z "$bare"
check "$JUSTFILE lint: does not run ruff with '$ARGS'" \
  contains "$recipe" "$ARGS"
check "$JUSTFILE lint: no 'ruff not found' failure when neither uvx nor mise is installed" \
  contains "$recipe" 'ruff not found'

if [ "$failures" -gt 0 ]; then
  echo "$failures of $assertions assertion(s) failed"
  exit 1
fi
echo "lint.yml and justfile both run ruff $ci_version with: $ARGS"
echo "PASS: $NAME ($assertions assertion(s))"
