#!/usr/bin/env bash
# consumer-sync-smoke — lint.yml must exercise the path consumers run, not
# only this repo's own `rulesync generate --check`.
#
# Consumers run reusable-sync-ai-rules.yml at @main: a config-less
# `rulesync fetch` of this repo followed by `generate --targets ...`. Neither
# reads rulesync.jsonc, so a rulesync bump that changes fetch (as v9 did with
# --path) or the no-config defaults passes `generate --check` here and breaks
# every caller once merged. lint.yml's "Consumer sync path" step runs those
# shipped steps in a scratch repo; this test pins that step.
#
# Asserts, on the shipped text (lint.yml and the sync workflow via yq):
#   - exactly one such step, before "Workflow tests", with no `if:` and no
#     `continue-on-error` (a step that can be skipped or ignored gates nothing);
#   - GITHUB_TOKEN is bound from github.token through env:, SYNC_WORKFLOW
#     names the shipped sync workflow, and TARGETS equals rulesync.jsonc;
#   - run against a stub npx (sentinel STUB-NPX) that simulates fetch from
#     this checkout: the shipped fetch and generate commands are what run, in
#     that order, and the checkout is left untouched (never generate at the
#     root);
#   - it fails when fetch writes nothing, when generate writes zero files or
#     covers only some targets, and when a step it extracts is renamed.
# Needs no network: the real fetch only runs in CI.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=consumer-sync-smoke
WORKFLOW=${1:-.github/workflows/lint.yml}
STEP='Consumer sync path (fetch + generate)'
export STEP

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
lacks() { ! contains "$1" "$2"; }
before() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }

# --- static shape -----------------------------------------------------------
count=$(yq '[.jobs.lint.steps[] | select(.name == strenv(STEP))] | length' "$WORKFLOW")
check "$WORKFLOW: expected exactly one step named '$STEP', found $count" test "$count" = 1
if [ "$count" != 1 ]; then
  echo "$failures failure(s)"
  exit 1
fi

sel='.jobs.lint.steps[] | select(.name == strenv(STEP))'
idx=$(yq '.jobs.lint.steps | to_entries | .[] | select(.value.name == strenv(STEP)) | .key' "$WORKFLOW")
tests_idx=$(yq '.jobs.lint.steps | to_entries | .[] | select(.value.name == "Workflow tests") | .key' "$WORKFLOW")
check "'$STEP' (index $idx) must come before 'Workflow tests' (index ${tests_idx:-missing})" before "$idx" "$tests_idx"
check "'$STEP' must have no if:" test "$(yq "$sel | has(\"if\")" "$WORKFLOW")" = false
check "'$STEP' must have no continue-on-error" test "$(yq "$sel | has(\"continue-on-error\")" "$WORKFLOW")" = false

token=$(yq "$sel | .env.GITHUB_TOKEN // \"\"" "$WORKFLOW")
sync_wf=$(yq "$sel | .env.SYNC_WORKFLOW // \"\"" "$WORKFLOW")
targets=$(yq "$sel | .env.TARGETS // \"\"" "$WORKFLOW")
body=$(yq "$sel | .run // \"\"" "$WORKFLOW")
# shellcheck disable=SC2016 # the literal expression, not an expansion
check "env GITHUB_TOKEN is '$token', expected '\${{ github.token }}'" test "$token" = '${{ github.token }}'
check "env SYNC_WORKFLOW '$sync_wf' must be .github/workflows/reusable-sync-ai-rules.yml" \
  test "$sync_wf" = .github/workflows/reusable-sync-ai-rules.yml
check "the run: body must not contain \${{ (bind values through env:)" lacks "$body" "\${{"

want_targets=$(python3 - <<'PY'
import json, re
text = open("rulesync.jsonc", encoding="utf-8").read()
text = re.sub(r"(?m)^\s*//.*$", "", text)
text = re.sub(r",(\s*[}\]])", r"\1", text)
print(",".join(json.loads(text)["targets"]))
PY
)
check "env TARGETS '$targets' != rulesync.jsonc targets '$want_targets'" test "$targets" = "$want_targets"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi

# --- behaviour against a stub npx ---------------------------------------------
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tmpdir"
cat >"$tmp/bin/npx" <<'STUB'
#!/usr/bin/env bash
# Simulates `rulesync fetch` (copy of this checkout's .rulesync) and
# `rulesync generate` (one file per rule and target), per STUB_FETCH/STUB_GEN.
set -euo pipefail
echo "STUB-NPX $*"
echo "$*" >>"$STUB_LOG"
[ "$#" -ge 2 ] || exit 64
case "$2" in
  fetch)
    [ "$STUB_FETCH" = ok ] || exit 0
    mkdir -p .rulesync
    cp -R "$STUB_SRC/.rulesync/rules" .rulesync/
    ;;
  generate)
    [ "$STUB_GEN" != zero ] || exit 0
    tg=
    while [ "$#" -gt 0 ]; do
      [ "$1" = --targets ] && { tg=$2; break; }
      shift
    done
    [ "$STUB_GEN" != partial ] || tg=${tg%%,*}
    IFS=',' read -ra ts <<<"$tg"
    for f in .rulesync/rules/*.md; do
      b=$(basename "$f" .md)
      for t in "${ts[@]}"; do
        case "$t" in
          claudecode) p=.claude/rules/$b.md ;;
          copilot) p=.github/instructions/$b.instructions.md ;;
          antigravity-ide) p=.agents/rules/$b.md ;;
          cursor) p=.cursor/rules/$b.mdc ;;
          *) exit 65 ;;
        esac
        mkdir -p "$(dirname "$p")"
        : >"$p"
      done
    done
    ;;
esac
STUB
chmod +x "$tmp/bin/npx"

n_rules=$(find .rulesync/rules -name '*.md' | wc -l)
check "this checkout has no .rulesync/rules/*.md to simulate a fetch with" test "$n_rules" -gt 0

out=
run_step() { # run_step <fetch-mode> <generate-mode> <sync-workflow>; sets $out, returns the step's rc
  : >"$tmp/log"
  local rc=0
  out=$(PATH="$tmp/bin:$PATH" TMPDIR="$tmp/tmpdir" STUB_LOG="$tmp/log" STUB_SRC="$PWD" \
    STUB_FETCH=$1 STUB_GEN=$2 GITHUB_TOKEN=stub-token SYNC_WORKFLOW=$3 TARGETS="$targets" \
    bash --noprofile --norc -eo pipefail -c "$body" 2>&1) || rc=$?
  return "$rc"
}

before_status=$(git status --porcelain)
rc=0
run_step ok ok "$sync_wf" || rc=$?
check "stub run: the step should pass, rc=$rc: $out" test "$rc" = 0
check "stub run: the stub npx did not run (sentinel STUB-NPX missing): $out" contains "$out" "STUB-NPX"
check "the checkout changed while the step ran (generate must not run at the root)" \
  test "$(git status --porcelain)" = "$before_status"

# The commands the stub saw are the shipped ones, read from the sync workflow.
fetch_line=$(yq '.jobs[].steps[] | select(.name == "Fetch rules from .github repo") | .run // ""' "$sync_wf")
fetch_args=${fetch_line#npx }
log=$(cat "$tmp/log")
first=$(sed -n 1p "$tmp/log")
second=$(sed -n 2p "$tmp/log")
check "stub run: first call should be the shipped fetch '$fetch_args', got '$first'" test "$first" = "$fetch_args"
check "stub run: fetch must pass --path .rulesync: '$first'" contains "$first" "--path .rulesync"
check "stub run: second call should be generate --targets $targets --features rules,ignore, got '$second'" \
  contains "$second" " generate --targets $targets --features rules,ignore"
check "stub run: expected exactly two npx calls, got: $log" test "$(wc -l <"$tmp/log")" -eq 2

rc=0
run_step empty ok "$sync_wf" || rc=$?
check "fetch writing nothing must fail the step (rc=$rc): $out" test "$rc" -ne 0
check "fetch writing nothing must stop before generate: $(cat "$tmp/log")" \
  lacks "$(cat "$tmp/log")" " generate "

rc=0
run_step ok zero "$sync_wf" || rc=$?
check "generate writing zero files must fail the step (rc=$rc): $out" test "$rc" -ne 0
check "generate writing zero files must name the target: $out" contains "$out" "::error::target"

rc=0
run_step ok partial "$sync_wf" || rc=$?
check "generate covering one target of '$targets' must fail the step (rc=$rc): $out" test "$rc" -ne 0

renamed="$tmp/renamed.yml"
yq '(.jobs[].steps[] | select(.name == "Verify rules were fetched") | .name) = "Check rules"' "$sync_wf" >"$renamed"
rc=0
run_step ok ok "$renamed" || rc=$?
check "a renamed sync-workflow step must fail the step (rc=$rc): $out" test "$rc" -ne 0
check "a renamed sync-workflow step must be reported: $out" contains "$out" "no run step named 'Verify rules were fetched'"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "PASS: $NAME ($assertions assertion(s))"
