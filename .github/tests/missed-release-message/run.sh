#!/usr/bin/env bash
# Regression test for #147: the missed-release step of
# reusable-release-please.yml names the right cause.
#
#   - A parse error comes from GitHub's 72-column wrap of the PR description
#     in the squash commit, not only from fenced code blocks, and the recovery
#     is a BEGIN_COMMIT_OVERRIDE section plus a workflow_dispatch run, not a
#     "fence-free" follow-up commit.
#   - In a monorepo config (`packages` in release-please-config.json), a
#     releasable commit whose files all sit outside every package path is
#     attributed to no package (sites#24). The step must report that instead
#     of a parse error.
#
# It EXTRACTS the shipped run body with yq and runs it under `bash -e` with a
# stub `gh` first on PATH that serves compare, contents and commit JSON.
# WORKFLOW overrides the file under test.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME="missed-release-message"
WORKFLOW=${WORKFLOW:-.github/workflows/reusable-release-please.yml}
STEP="Check for releasable commits release-please did not consider"
SENTINEL=STUB-GH-7c20d4

fatal() { echo "FAIL: $NAME: $*"; exit 1; }
command -v yq >/dev/null || fatal "yq is required"
command -v jq >/dev/null || fatal "jq is required"
[ -f "$WORKFLOW" ] || fatal "$WORKFLOW not found"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

assertions=0
failures=0
CASE=setup
ok() { assertions=$((assertions + 1)); }
bad() { assertions=$((assertions + 1)); failures=$((failures + 1)); echo "  FAIL [$CASE] $*"; }
expect() { if [ "$1" = "$2" ]; then ok; else bad "$3: expected '$2', got '$1'"; fi; }
has() { if grep -Fq -- "$2" <<<"$1"; then ok; else bad "$3: missing '$2'"; fi; }
hasnt() { if grep -Fq -- "$2" <<<"$1"; then bad "$3: unexpected '$2'"; else ok; fi; }

[ "$(STEP="$STEP" yq '[.jobs[].steps[] | select(.name == strenv(STEP))] | length' "$WORKFLOW")" = 1 ] ||
  fatal "expected exactly one step named '$STEP' in $WORKFLOW"
STEP="$STEP" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .run' "$WORKFLOW" >"$work/step.sh"
[ -s "$work/step.sh" ] || fatal "empty run body for '$STEP'"

CASE=contract
if grep -Fq '${{' "$work/step.sh"; then bad "run body interpolates \${{ }}"; else ok; fi
config_env=$(STEP="$STEP" yq -r '.jobs[].steps[] | select(.name == strenv(STEP)) | .env.CONFIG_FILE // ""' "$WORKFLOW")
# shellcheck disable=SC2016
expect "$config_env" '${{ inputs.config-file }}' "env.CONFIG_FILE"
body=$(cat "$work/step.sh")
hasnt "$body" "fence-free" "the old fence-free remedy is gone"

# ------------------------------------------------------------------ stub gh
# Fixture files: $work/compare.json, $work/config.json (absent = 404) and
# $work/files/<sha> (one changed path per line).
mkdir -p "$work/bin" "$work/files"
cat >"$work/bin/gh" <<STUB
#!/usr/bin/env bash
echo "$SENTINEL \$*" >>"$work/gh.log"
args="\$*"
case "\$args" in
  *"repos/org/app/compare/"*) cat "$work/compare.json" ;;
  *"repos/org/app/contents/release-please-config.json?ref=after000"*)
    if [ -f "$work/config.json" ]; then cat "$work/config.json"; else echo '{"message":"Not Found"}'; exit 1; fi ;;
  *"repos/org/app/commits/"*)
    sha=\${args##*repos/org/app/commits/}; sha=\${sha%% *}
    [ -f "$work/files/\$sha" ] || { echo "no files fixture for \$sha" >&2; exit 1; }
    jq -Rn --arg sha "\$sha" '{sha: \$sha, files: [inputs | {filename: .}]}' <"$work/files/\$sha" ;;
  *) echo "unexpected gh call: \$args" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/gh"
command -v "$work/bin/gh" >/dev/null || fatal "stub gh is not executable"

# commit SHA SUBJECT FILE...: appends a compare commit and its files fixture.
commits='[]'
commit() {
  local sha=$1 subject=$2
  shift 2
  commits=$(jq -c --arg sha "$sha" --arg m "$subject" '. + [{sha: $sha, commit: {message: $m}}]' <<<"$commits")
  printf '%s\n' "$@" >"$work/files/$sha"
}
# run MODE: runs the step; sets rc, out, summary.
run() {
  jq -n --argjson c "$commits" '{commits: $c, files: []}' >"$work/compare.json"
  : >"$work/summary"; : >"$work/output"; : >"$work/gh.log"
  rc=0
  out=$(PATH="$work/bin:$PATH" GH_TOKEN=x REPO=org/app BEFORE=before000 AFTER=after000 MODE="$1" \
    TYPES='feat,fix,perf,revert' CONFIG_FILE=release-please-config.json \
    GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary" \
    bash --noprofile --norc -e "$work/step.sh" 2>&1) || rc=$?
  summary=$(cat "$work/summary")
  has "$(cat "$work/gh.log")" "$SENTINEL" "stub gh was called"
}
reset() { commits='[]'; rm -f "$work/config.json" "$work/files"/*; }

# The parse-error wording, asserted wherever a parse error is the reported cause.
expect_parse_wording() {
  has "$summary" "72" "names GitHub's 72-column wrap"
  has "$summary" "BEGIN_COMMIT_OVERRIDE" "recovery: override section"
  has "$summary" "END_COMMIT_OVERRIDE" "recovery: override section end"
  has "$summary" "workflow_dispatch" "recovery: dispatch release-please"
  has "$summary" "COMMIT_MESSAGES" "prevention: COMMIT_MESSAGES"
  hasnt "$summary" "fence-free" "no fence-free remedy"
}

# ------------------------------------------------- single package, no config
CASE=single-package
reset
commit aaaaaaa1111111111111111111111111111111aa 'feat: add export' src/export.ts
run warn
expect "$rc" 0 "warn mode exit"
expect "$(sed -n 's/^missed_release=//p' "$work/output")" true "missed_release output"
expect_parse_wording
has "$summary" '`aaaaaaa` feat: add export' "lists the commit"
hasnt "$summary" "registered package" "no package wording without a packages config"
has "$out" "::warning::" "warning annotation"
has "$out" "parse error" "annotation names a parse error"

# ----------------------------------------- monorepo: commit outside packages
CASE=unregistered
reset
printf '%s\n' '{"packages": {"sites/example-static": {}, "sites/other/": {}}}' >"$work/config.json"
commit bbbbbbb2222222222222222222222222222222bb 'feat(sites/epowermove-afir): add site' sites/epowermove-afir/index.html sites/epowermove-afir/style.css
run warn
expect "$rc" 0 "warn mode exit"
has "$summary" "touch no registered package" "unregistered heading"
has "$summary" '`bbbbbbb` feat(sites/epowermove-afir): add site' "lists the unregistered commit"
has "$summary" '`sites/example-static`' "names the registered package paths"
has "$summary" '`sites/other`' "names the registered package paths, trailing slash dropped"
hasnt "$summary" "BEGIN_COMMIT_OVERRIDE" "no parse-error recovery for an unregistered commit"
has "$out" "::warning::" "warning annotation"
has "$out" "no registered package" "annotation names the unregistered cause"
hasnt "$out" "parse error" "annotation does not blame a parse error"

CASE=unregistered-error-mode
run error
expect "$rc" 1 "error mode exit"
has "$out" "::error::" "error annotation"

# --------------------------------------------- monorepo: commit in a package
CASE=registered
reset
printf '%s\n' '{"packages": {"sites/example-static": {}, "sites/epowermove-afir": {}}}' >"$work/config.json"
commit ccccccc3333333333333333333333333333333cc 'fix(sites/example-static): typo' sites/example-static/index.html README.md
run warn
expect "$rc" 0 "warn mode exit"
expect_parse_wording
hasnt "$summary" "touch no registered package" "a commit inside a package is not unregistered"
has "$out" "parse error" "annotation names a parse error"

# ------------------------------------------------------- monorepo: mixed range
CASE=mixed
reset
printf '%s\n' '{"packages": {"sites/example-static": {}}}' >"$work/config.json"
commit ddddddd4444444444444444444444444444444dd 'feat(sites/new): add' sites/new/a.html
commit eeeeeee5555555555555555555555555555555ee 'fix(sites/example-static): b' sites/example-static/b.html
run warn
has "$summary" "touch no registered package" "unregistered section"
has "$summary" "BEGIN_COMMIT_OVERRIDE" "parse-error section"
has "$out" "no registered package" "annotation names both causes (package)"
has "$out" "parse error" "annotation names both causes (parse)"

# ----------------------------------------------- root package covers everything
CASE=root-package
reset
printf '%s\n' '{"packages": {".": {}, "sites/example-static": {}}}' >"$work/config.json"
commit fffffff6666666666666666666666666666666ff 'feat: top-level change' docs/x.md
run warn
hasnt "$summary" "touch no registered package" "the root package claims every commit"
expect_parse_wording

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $assertions assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($assertions assertion(s))"
