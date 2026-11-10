#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted ${{ }} and $default-branch are literal expected values
# gitleaks-reusable — reusable-gitleaks.yml carries this repo's
# fvh-gcp-project-id rule to other public FVH repos (#149), and its shipped
# steps do what they say.
#
#   1. Drift: the rule block between `# BEGIN fvh-gcp-project-id` and
#      `# END fvh-gcp-project-id` in the `Write FVH gitleaks config` step is
#      byte-identical to `.gitleaks.toml` from its first `[[rules]]` line to
#      EOF. The rule is embedded rather than fetched because a called workflow
#      cannot learn its own ref, so a fetched config would float at @main even
#      for a caller pinned by SHA.
#   2. Install: the `Install gitleaks` step is lint.yml's `gitleaks` step
#      verbatim (env and run body), minus lint.yml's own scan line. tool-pins
#      checks the version and checksum against the justfile and Renovate.
#   3. Static contract: top-level `permissions: {contents: read}`, one job on
#      `inputs.runner` (default ubuntu-slim), no step with an `if:`, Validate
#      first, a SHA-pinned checkout with persist-credentials: false, Enforce
#      last and the only step with continue-on-error (exactly
#      `inputs.enforcement == 'warn'`), so warn softens findings and never a
#      scan that did not complete; no `run:` body contains `${{`, and every
#      `steps.<id>.outputs.<key>` resolves to a step that writes that key.
#   4. Behaviour: the shipped `run:` bodies of Validate, Write config, Scan and
#      Enforce, extracted with yq and run in order under the job's shell
#      against fixture workspaces with the real gitleaks binary (or a stub, for
#      the outcomes gitleaks cannot be made to produce). The harness applies
#      each step's continue-on-error to derive the job's conclusion. FVH-shaped
#      fixture IDs are assembled at run time, so this file passes the
#      tree-wide scan.
#      On `pull_request` (#213) the caller's config and .gitleaksignore come
#      from the base commit, so the scenarios in 4o build a merge commit the
#      way refs/pull/N/merge is laid out (first parent the base) and check
#      that a config, an allowlist or an ignore entry the pull request adds
#      does not reach its own scan, each against a `push` control over the
#      same tree where it does.
#   5. The starter template calls the workflow at @main on pull_request and
#      push to the default branch, with `contents: read`.
#
# Usage: run.sh [ROOT]   (default: the repo root; the teeth check runs it on a
#                         scratch copy with the regex in .gitleaks.toml edited)
# Needs: bash, yq v4 (mikefarah), jq, gitleaks on PATH (lint.yml installs it).
set -euo pipefail
cd "${1:-$(git rev-parse --show-toplevel)}"

NAME=gitleaks-reusable
WF=.github/workflows/reusable-gitleaks.yml
LINT=.github/workflows/lint.yml
TPL=workflow-templates/gitleaks.yml
ASSERTIONS=0

fail() {
  echo "FAIL: ${NAME}: $*" >&2
  exit 1
}
pass() { ASSERTIONS=$((ASSERTIONS + 1)); }
expect_eq() { # description, expected, actual
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
  pass
}
expect_contains() { # description, needle, haystack
  grep -Fq -- "$2" <<<"$3" || fail "$1: [$2] not found in:
$3"
  pass
}
expect_absent() { # description, needle, haystack
  if grep -Fq -- "$2" <<<"$3"; then fail "$1: [$2] unexpectedly present in:
$3"; fi
  pass
}

for tool in yq jq gitleaks; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done
[ -f "$WF" ] || fail "$WF does not exist"
[ -f .gitleaks.toml ] || fail ".gitleaks.toml does not exist"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

step_field() { # step name, yq field expression (e.g. .run)
  STEP="$1" yq "[.jobs[].steps[] | select(.name == strenv(STEP))] | .[0] | $2 // \"\"" "$WF"
}

# ---------------------------------------------------------------------------
# 1. Drift between the embedded rule block and .gitleaks.toml
# ---------------------------------------------------------------------------
WRITE_STEP='Write FVH gitleaks config'
write_body=$(step_field "$WRITE_STEP" .run)
[ -n "$write_body" ] || fail "no run step named '$WRITE_STEP' in $WF"
expect_eq "BEGIN marker appears once in '$WRITE_STEP'" 1 "$(grep -c '^# BEGIN fvh-gcp-project-id$' <<<"$write_body" || true)"
expect_eq "END marker appears once in '$WRITE_STEP'" 1 "$(grep -c '^# END fvh-gcp-project-id$' <<<"$write_body" || true)"
printf '%s\n' "$write_body" | sed -n '/^# BEGIN fvh-gcp-project-id$/,/^# END fvh-gcp-project-id$/p' | sed '1d;$d' >"$TMP/embedded.toml"
sed -n '/^\[\[rules\]\]/,$p' .gitleaks.toml >"$TMP/shipped.toml"
[ -s "$TMP/shipped.toml" ] || fail ".gitleaks.toml has no [[rules]] section (harness broken?)"
[ -s "$TMP/embedded.toml" ] || fail "the BEGIN/END block in '$WRITE_STEP' is empty"
if ! cmp -s "$TMP/shipped.toml" "$TMP/embedded.toml"; then
  fail "the fvh-gcp-project-id block in $WF has drifted from .gitleaks.toml ([[rules]] to EOF); copy it across:
$(diff -u "$TMP/shipped.toml" "$TMP/embedded.toml" | sed 's/^/    /')"
fi
pass

# ---------------------------------------------------------------------------
# 2. The install step is lint.yml's gitleaks step, verbatim
# ---------------------------------------------------------------------------
lint_body=$(yq '[.jobs.lint.steps[] | select(.name == "gitleaks")] | .[0].run // ""' "$LINT")
[ -n "$lint_body" ] || fail "no step named 'gitleaks' in $LINT"
lint_scan=$(tail -n 1 <<<"$lint_body")
expect_contains "lint.yml's gitleaks step ends with its own scan" 'gitleaks" dir ' "$lint_scan"
expect_eq "Install gitleaks run body == lint.yml's gitleaks step minus its scan line" \
  "$(sed '$d' <<<"$lint_body")" "$(step_field 'Install gitleaks' .run)"
expect_eq "Install gitleaks env == lint.yml's gitleaks env" \
  "$(yq -o=json -I0 '[.jobs.lint.steps[] | select(.name == "gitleaks")] | .[0].env' "$LINT")" \
  "$(step_field 'Install gitleaks' '.env' | yq -o=json -I0 '.')"

# ---------------------------------------------------------------------------
# 3. Static contract
# ---------------------------------------------------------------------------
expect_eq "top-level permissions" '{"contents":"read"}' "$(yq -o=json -I0 '.permissions' "$WF")"
expect_eq "exactly one job" 1 "$(yq '.jobs | length' "$WF")"
expect_eq "runs-on" '${{ inputs.runner }}' "$(yq '.jobs[].runs-on' "$WF")"
expect_eq "runner default" ubuntu-slim "$(yq '.on.workflow_call.inputs.runner.default' "$WF")"
expect_eq "enforcement default" block "$(yq '.on.workflow_call.inputs.enforcement.default' "$WF")"
expect_eq "config-path default" .gitleaks.toml "$(yq '.on.workflow_call.inputs.config-path.default' "$WF")"
expect_eq "job shell is bash (the harness runs bodies under it)" bash "$(yq '.jobs[].defaults.run.shell' "$WF")"
expect_eq "no step has an if:" 0 "$(yq '[.jobs[].steps[] | select(has("if"))] | length' "$WF")"
expect_eq "first step" "Validate inputs" "$(yq '.jobs[].steps[0].name' "$WF")"
checkout=$(yq '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | .[0].uses // ""' "$WF")
[[ "$checkout" =~ ^actions/checkout@[0-9a-f]{40}$ ]] || fail "checkout is not SHA-pinned: [$checkout]"
pass
grep -Eq "uses: actions/checkout@[0-9a-f]{40} # v[0-9]" "$WF" || fail "checkout pin has no '# vX' version comment"
pass
expect_eq "checkout persist-credentials" false \
  "$(yq '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | .[0].with.persist-credentials' "$WF")"
# Depth 2 puts the merge commit's first parent (the base commit) in the clone;
# the Write step reads the caller's config from it on pull_request (#213).
expect_eq "checkout fetch-depth" 2 \
  "$(yq '[.jobs[].steps[] | select(.uses // "" | test("^actions/checkout@"))] | .[0].with.fetch-depth' "$WF")"
expect_eq "Write config reads the event name through env:" '${{ github.event_name }}' "$(step_field "$WRITE_STEP" '.env.EVENT_NAME')"
COE_WARN="\${{ inputs.enforcement == 'warn' }}"
expect_eq "last step" Enforce "$(yq '.jobs[].steps[-1].name' "$WF")"
expect_eq "Enforce continue-on-error" "$COE_WARN" "$(step_field Enforce '.continue-on-error')"
expect_eq "Scan has no continue-on-error (a broken scan is red under warn too)" "" "$(step_field Scan '.continue-on-error')"
expect_eq "only Enforce carries continue-on-error" '["Enforce"]' \
  "$(yq -o=json -I0 '[.jobs[].steps[] | select(has("continue-on-error")) | .name]' "$WF")"
expect_eq "Enforce reads the count through env:" '${{ steps.scan.outputs.findings }}' "$(step_field Enforce '.env.FINDINGS')"
expect_eq "no run: body contains \${{" 0 "$(yq '[.jobs[].steps[] | select(.run // "" | test("\$\{\{"))] | length' "$WF")"
expect_eq "no uses: other than a SHA-pinned action" 0 \
  "$(yq '[.jobs[].steps[] | select(has("uses")) | select(.uses | test("@[0-9a-f]{40}$") | not)] | length' "$WF")"

refs=$(grep -oE 'steps\.[A-Za-z0-9_-]+\.outputs\.[A-Za-z0-9_-]+' "$WF" | LC_ALL=C sort -u || true)
[ -n "$refs" ] || fail "found no steps.<id>.outputs.<key> reference (the findings output is gone?)"
pass
while IFS= read -r ref; do
  id=${ref#steps.}; id=${id%%.*}; key=${ref##*.}
  body=$(ID="$id" yq '[.jobs[].steps[] | select(.id == strenv(ID))] | .[0].run // ""' "$WF")
  [ -n "$body" ] || fail "$ref: no step with id '$id' (a mistyped id evaluates to '')"
  grep -Eq "(^|[^A-Za-z0-9_-])${key}=" <<<"$body" || fail "$ref: step '$id' never writes '${key}=' to \$GITHUB_OUTPUT"
  pass
done <<<"$refs"
expect_eq "workflow output findings" '${{ jobs.gitleaks.outputs.findings }}' "$(yq '.on.workflow_call.outputs.findings.value' "$WF")"

# ---------------------------------------------------------------------------
# 4. Behaviour of the shipped steps
# ---------------------------------------------------------------------------
declare -A INPUT
EVENT=push
reset_inputs() {
  INPUT=()
  EVENT=push
  local k
  for k in $(yq '.on.workflow_call.inputs | keys | .[]' "$WF"); do
    INPUT[$k]=$(K="$k" yq '.on.workflow_call.inputs[strenv(K)].default' "$WF")
  done
}

# Runs one shipped step in $WS. Env values that are `${{ inputs.X }}` take
# INPUT[X], `${{ github.event_name }}` takes EVENT (reset_inputs sets push),
# `${{ steps.<id>.outputs.<key> }}` the last `<key>=` line in the
# scenario's GITHUB_OUTPUT (only Scan writes one); any other expression is a
# harness gap and fails.
run_step() { # step name ; uses WS, RT
  local step="$1" body key val envs=()
  body=$(step_field "$step" .run)
  [ -n "$body" ] || fail "no run step named '$step' in $WF"
  while IFS=$'\t' read -r key val; do
    [ -n "$key" ] || continue
    if [[ "$val" =~ ^\$\{\{\ *inputs\.([A-Za-z0-9_-]+)\ *\}\}$ ]]; then
      val=${INPUT[${BASH_REMATCH[1]}]-}
    elif [[ "$val" =~ ^\$\{\{\ *github\.event_name\ *\}\}$ ]]; then
      val=$EVENT
    elif [[ "$val" =~ ^\$\{\{\ *steps\.[A-Za-z0-9_-]+\.outputs\.([A-Za-z0-9_-]+)\ *\}\}$ ]]; then
      val=$(sed -n "s/^${BASH_REMATCH[1]}=//p" "$RT/output" | tail -n 1)
    elif [[ "$val" == *'${{'* ]]; then
      fail "step '$step' env $key=$val: expression the harness cannot resolve"
    fi
    envs+=("$key=$val")
  done < <(STEP="$step" yq '[.jobs[].steps[] | select(.name == strenv(STEP))] | .[0].env // {} | to_entries | .[] | .key + "	" + (.value | tostring)' "$WF")
  (cd "$WS" && env "${envs[@]}" RUNNER_TEMP="$RT" GITHUB_WORKSPACE="$WS" \
    GITHUB_OUTPUT="$RT/output" GITHUB_STEP_SUMMARY="$RT/summary" GITHUB_PATH="$RT/path" \
    bash --noprofile --norc -eo pipefail -c "$body")
}

new_ws() { # scenario name
  WS="$TMP/$1/ws" RT="$TMP/$1/rt"
  mkdir -p "$WS" "$RT"
  : >"$RT/output"; : >"$RT/summary"; : >"$RT/path"
  # Where the (not executed) Install step puts the binary.
  mkdir -p "$RT/bin"
  ln -s "$(command -v gitleaks)" "$RT/bin/gitleaks"
  git -C "$WS" init -q .
}

# Whether a failed step's continue-on-error keeps the job going.
soft_fail() { # step name
  local coe
  coe=$(step_field "$1" '.continue-on-error')
  case "$coe" in
    '') return 1 ;;
    "$COE_WARN") [ "${INPUT[enforcement]}" = warn ] ;;
    *) fail "step '$1' continue-on-error [$coe]: expression the harness cannot resolve" ;;
  esac
}

# Runs Validate, Write config, Scan and Enforce as the runner would: a failed
# step stops the job unless its continue-on-error is true. Sets OUT
# (stdout+stderr of every step run), RC (the first non-zero step exit, 0 if
# all passed), FAILED (the names of the steps that failed, space-separated)
# and JOB (the job's conclusion: success or failure).
run_job() {
  local s rc
  OUT="" RC=0 FAILED="" JOB=success
  for s in "Validate inputs" "$WRITE_STEP" Scan Enforce; do
    rc=0
    OUT+=$(run_step "$s" 2>&1) || rc=$?
    OUT+=$'\n'
    [ "$rc" -eq 0 ] && continue
    [ "$RC" -ne 0 ] || RC=$rc
    FAILED+="${FAILED:+ }$s"
    soft_fail "$s" && continue
    JOB=failure
    return 0
  done
}

rule_count() { # rule id ; counts findings in the scenario's report
  jq --arg r "$1" '[.[] | select(.RuleID == $r)] | length' "$RT/gitleaks.json"
}

# Fixture identifiers, assembled at run time (not real FVH IDs).
fvh_prefix="fvh-project"
region="europe-north1"
aws_key="AKIA""QYLPMN5HHHFPZAM2"

write_fixtures() {
  mkdir -p "$WS/docs"
  cat >"$WS/docs/deploy.md" <<EOF
serviceAccount: app@${fvh_prefix}-staging.iam.gserviceaccount.com
connection: "sample-project:${region}:db-1"
placeholder: "my-project:${region}:my-instance"
EOF
  printf 'aws_access_key_id = %s\n' "$aws_key" >"$WS/docs/creds.ini"
}

# 4a. Validate rejects every enforcement value but block and warn, before any
# other step runs.
for bad in true enforce Block '' 'block ' warning; do
  reset_inputs; INPUT[enforcement]=$bad; new_ws "enf-$ASSERTIONS"
  rc=0; out=$(run_step "Validate inputs" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Validate accepted enforcement '$bad'"
  expect_contains "Validate error names enforcement ('$bad')" "::error::enforcement" "$out"
done
for good in block warn; do
  reset_inputs; INPUT[enforcement]=$good; new_ws "enf-ok-$good"
  run_step "Validate inputs" >/dev/null 2>&1 || fail "Validate rejected enforcement '$good'"
  pass
done

# 4b. Validate rejects a config-path outside the checkout or one that would
# break the TOML string it is written into.
for bad in ../x /etc/x 'a/../../x' .. '' "x'y" 'x"y' 'x y' $'x\ny'; do
  reset_inputs; INPUT[config-path]=$bad; new_ws "cfg-$ASSERTIONS"
  rc=0; out=$(run_step "Validate inputs" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "Validate accepted config-path [$bad]"
  expect_contains "Validate error names config-path ([$bad])" "::error::config-path" "$out"
done
for good in .gitleaks.toml ./.gitleaks.toml config/gitleaks.toml a..b.toml; do
  reset_inputs; INPUT[config-path]=$good; new_ws "cfg-ok-$ASSERTIONS"
  run_step "Validate inputs" >/dev/null 2>&1 || fail "Validate rejected config-path '$good'"
  pass
done

# 4c. No caller config: the default rules and the FVH rule run; block mode.
reset_inputs; new_ws no-config; write_fixtures
run_job
[ "$RC" -ne 0 ] || fail "no-config: Scan passed with findings in the tree"
pass
expect_eq "no-config: fvh-gcp-project-id findings (placeholder allowlisted)" 2 "$(rule_count fvh-gcp-project-id)"
expect_eq "no-config: default rule aws-access-token fires" 1 "$(rule_count aws-access-token)"
expect_contains "no-config: config uses the default rules" "useDefault = true" "$(cat "$RT/fvh-gitleaks.toml")"
expect_eq "no-config: findings output" "findings=3" "$(cat "$RT/output")"
expect_eq "no-config: one ::error annotation per finding" 3 "$(grep -c '^::error file=docs/' <<<"$OUT" || true)"
expect_contains "no-config: annotation carries file and line" "::error file=docs/deploy.md,line=1,title=gitleaks fvh-gcp-project-id::" "$OUT"
expect_absent "no-config: the secret never reaches the log" "$aws_key" "$OUT"
expect_absent "no-config: the secret never reaches the summary" "$aws_key" "$(cat "$RT/summary")"
expect_contains "no-config: summary table header" "| RuleID | File | Line |" "$(cat "$RT/summary")"
expect_contains "no-config: summary row" "| fvh-gcp-project-id | docs/deploy.md | 2 |" "$(cat "$RT/summary")"
expect_eq "no-config: job conclusion" failure "$JOB"
expect_eq "no-config: only Enforce failed" Enforce "$FAILED"
# --redact itself, not only its effect on the log (annotations never carry the
# match): every finding in the report is redacted.
expect_eq "no-config: every report Secret is REDACTED (--redact)" '["REDACTED"]' \
  "$(jq -c '[.[].Secret] | unique' "$RT/gitleaks.json")"
expect_absent "no-config: the secret never reaches the report" "$aws_key" "$(cat "$RT/gitleaks.json")"
expect_absent "no-config: no caller config, no useDefault warning" "useDefault = true, so" "$OUT"

# 4d. Same tree, warn: Enforce still fails (the job stays green only through
# its continue-on-error), Scan does not, and annotations are warnings.
reset_inputs; INPUT[enforcement]=warn; new_ws warn; write_fixtures
run_job
[ "$RC" -ne 0 ] || fail "warn: no step failed with findings"
pass
expect_eq "warn: only Enforce failed" Enforce "$FAILED"
expect_eq "warn: job conclusion" success "$JOB"
expect_eq "warn: one ::warning annotation per finding" 3 "$(grep -c '^::warning file=docs/' <<<"$OUT" || true)"
expect_eq "warn: no per-finding ::error annotation" 0 "$(grep -c '^::error file=' <<<"$OUT" || true)"
expect_eq "warn: findings output" "findings=3" "$(cat "$RT/output")"

# 4e. Clean tree (placeholder only): green, findings=0.
reset_inputs; new_ws clean
printf 'connection: "my-project:%s:my-instance"\n' "$region" >"$WS/README.md"
run_job
expect_eq "clean: job exit" 0 "$RC"
expect_eq "clean: job conclusion" success "$JOB"
expect_eq "clean: findings output" "findings=0" "$(cat "$RT/output")"
expect_contains "clean: summary says no leaks" "No leaks found" "$(cat "$RT/summary")"

# 4f. A caller config with useDefault and a custom rule: all three rule
# families fire.
caller_rule() { # file, with-useDefault (yes|no)
  {
    if [ "$2" = yes ]; then printf '[extend]\nuseDefault = true\n\n'; fi
    printf '[[rules]]\nid = "caller-token"\nregex = '"'''"'caller-secret-[0-9]{6}'"'''"'\n'
  } >"$1"
}
reset_inputs; new_ws caller-default; write_fixtures
caller_rule "$WS/.gitleaks.toml" yes
echo "token: caller-secret-""123456" >"$WS/docs/app.txt"
run_job
[ "$RC" -ne 0 ] || fail "caller-default: Scan passed with findings"
pass
expect_contains "caller-default: config extends the caller's file" "path = '$WS/.gitleaks.toml'" "$(cat "$RT/fvh-gitleaks.toml")"
expect_eq "caller-default: caller rule fires" 1 "$(rule_count caller-token)"
expect_eq "caller-default: FVH rule fires" 2 "$(rule_count fvh-gcp-project-id)"
expect_eq "caller-default: default rule fires through the caller's useDefault" 1 "$(rule_count aws-access-token)"
expect_absent "caller-default: no useDefault warning" "useDefault = true, so" "$OUT"

# 4g. A caller config without useDefault: gitleaks reads it as written, so the
# default rules do not run (and the run says so); the FVH rule still does.
reset_inputs; new_ws caller-nodefault; write_fixtures
caller_rule "$WS/.gitleaks.toml" no
echo "token: caller-secret-""123456" >"$WS/docs/app.txt"
run_job
expect_eq "caller-nodefault: caller rule fires" 1 "$(rule_count caller-token)"
expect_eq "caller-nodefault: FVH rule fires" 2 "$(rule_count fvh-gcp-project-id)"
expect_eq "caller-nodefault: no default rules without useDefault" 0 "$(rule_count aws-access-token)"
expect_contains "caller-nodefault: warns that the default rules are off" \
  "::warning file=.gitleaks.toml::.gitleaks.toml does not set [extend] useDefault = true, so gitleaks' default secret rules are not running" "$OUT"
# useDefault = false is the same thing written out.
reset_inputs; new_ws caller-default-false
printf '[extend]\nuseDefault = false\n' >"$WS/.gitleaks.toml"
run_job
expect_contains "caller-default-false: warns that the default rules are off" "does not set [extend] useDefault = true" "$OUT"

# 4h. A caller config that extends another file gets a warning (gitleaks
# ignores [extend] two levels below the workflow's config).
reset_inputs; new_ws caller-nested; write_fixtures
printf '[extend]\npath = "base.toml"\n' >"$WS/.gitleaks.toml"
caller_rule "$WS/base.toml" yes
run_job
expect_contains "caller-nested: warns about the nested extend" "::warning file=.gitleaks.toml::.gitleaks.toml extends another file." "$OUT"
# A rule's own `path` field is not an [extend] and must not warn.
reset_inputs; new_ws caller-rule-path; write_fixtures
caller_rule "$WS/.gitleaks.toml" yes
printf '[[rules]]\nid = "env-file"\npath = %s\n' "'''\\.env\$'''" >>"$WS/.gitleaks.toml"
run_job
expect_eq "caller-rule-path: the caller config parses (FVH rule fires)" 2 "$(rule_count fvh-gcp-project-id)"
expect_absent "caller-rule-path: no nested-extend warning for a rule path" "::warning file=.gitleaks.toml::" "$OUT"

# 4i. A non-default config-path must exist; the default one may be absent.
reset_inputs; INPUT[config-path]=config/gitleaks.toml; new_ws custom-missing; write_fixtures
run_job
[ "$RC" -ne 0 ] || fail "custom-missing: a missing non-default config-path was ignored"
pass
expect_contains "custom-missing: error names the path" "::error::config-path 'config/gitleaks.toml'" "$OUT"
[ ! -e "$RT/gitleaks.json" ] || fail "custom-missing: the scan ran anyway"
pass
reset_inputs; INPUT[config-path]=config/gitleaks.toml; new_ws custom-present; write_fixtures
mkdir -p "$WS/config"; caller_rule "$WS/config/gitleaks.toml" yes
echo "token: caller-secret-""123456" >"$WS/docs/app.txt"
run_job
expect_eq "custom-present: caller rule fires" 1 "$(rule_count caller-token)"

# 4j. Annotation properties are %-escaped: a file name with %, comma, colon
# and a newline produces one annotation line with the name intact.
reset_inputs; new_ws escaping
odd=$'odd%,na:me\nx.md'
printf 'id: %s-sample\n' "$fvh_prefix" >"$WS/$odd"
run_job
expect_contains "escaping: file= property escaped" "::error file=odd%25%2Cna%3Ame%0Ax.md,line=1,title=gitleaks fvh-gcp-project-id::" "$OUT"
expect_eq "escaping: no stray line from the file name" 0 "$(grep -c '^x\.md' <<<"$OUT" || true)"
expect_contains "escaping: summary row on one line" "| fvh-gcp-project-id | odd%,na:me x.md | 1 |" "$(cat "$RT/summary")"

# 4j'. A '|' in a file name is escaped in the summary table, and a rule
# description from the caller's config (a newline and a '%') stays on its
# annotation line: unescaped, its second line would be a workflow command.
reset_inputs; new_ws escaping-msg
caller_rule "$WS/.gitleaks.toml" yes
printf '[[rules]]\nid = "caller-desc"\ndescription = "%s"\nregex = %s\n' \
  'first\n::error::forged 100%' "'''desc-secret-[0-9]{6}'''" >>"$WS/.gitleaks.toml"
echo "value: desc-secret-""654321" >"$WS/app.txt"
printf 'id: %s-sample\n' "$fvh_prefix" >"$WS/pi|pe.md"
run_job
expect_contains "escaping-msg: '|' escaped in the summary row" '| fvh-gcp-project-id | pi\|pe.md | 1 |' "$(cat "$RT/summary")"
expect_contains "escaping-msg: description newline and % escaped" \
  "::error file=app.txt,line=1,title=gitleaks caller-desc::first%0A::error::forged 100%25" "$OUT"
expect_eq "escaping-msg: no forged command line" 0 "$(grep -c '^::error::forged' <<<"$OUT" || true)"

# 4k. A gitleaks error (unparseable caller config) fails without claiming
# findings: the leak exit code is not gitleaks' generic error code.
reset_inputs; new_ws broken-config; write_fixtures
echo 'not toml [[' >"$WS/.gitleaks.toml"
run_job
[ "$RC" -ne 0 ] || fail "broken-config: Scan passed with an unparseable config"
pass
expect_contains "broken-config: error says the scan did not complete" "without completing the scan" "$OUT"
expect_eq "broken-config: no findings output" "" "$(cat "$RT/output")"
expect_eq "broken-config: Scan failed" Scan "$FAILED"
expect_eq "broken-config: job conclusion" failure "$JOB"

# 4l. Under warn, a scan that did not complete still fails the job: the
# failing step is Scan, which carries no continue-on-error.
reset_inputs; INPUT[enforcement]=warn; new_ws broken-config-warn; write_fixtures
echo 'not toml [[' >"$WS/.gitleaks.toml"
run_job
expect_contains "broken-config-warn: error says the scan did not complete" "without completing the scan" "$OUT"
expect_eq "broken-config-warn: Scan failed" Scan "$FAILED"
expect_eq "broken-config-warn: job conclusion" failure "$JOB"
expect_eq "broken-config-warn: no findings output" "" "$(cat "$RT/output")"
# The same with gitleaks' own extend.path/useDefault conflict.
reset_inputs; INPUT[enforcement]=warn; new_ws extend-conflict-warn; write_fixtures
printf '[extend]\nuseDefault = true\npath = "other.toml"\n' >"$WS/.gitleaks.toml"
: >"$WS/other.toml"
run_job
expect_eq "extend-conflict-warn: Scan failed" Scan "$FAILED"
expect_eq "extend-conflict-warn: job conclusion" failure "$JOB"

# 4m. Outcomes the real binary cannot be made to produce, from a stub in its
# place: each is a scan that did not complete, red in both modes, with no
# findings output.
stub_gitleaks() { # exit code, report content ('-' writes none)
  rm -f "$RT/bin/gitleaks"
  {
    echo '#!/usr/bin/env bash'
    echo 'while [ $# -gt 0 ]; do [ "$1" = --report-path ] && report=$2; shift; done'
    [ "$2" = - ] || printf 'printf %%s %q >"$report"\n' "$2"
    echo "exit $1"
  } >"$RT/bin/gitleaks"
  chmod +x "$RT/bin/gitleaks"
}
for mode in block warn; do
  for stub in '2|[]|report is empty' '2|-|wrote no readable report' '0|{}|wrote no readable report' \
    '0|not json|wrote no readable report' '126|[]|exited 126 without completing the scan'; do
    IFS='|' read -r code report msg <<<"$stub"
    reset_inputs; INPUT[enforcement]=$mode; new_ws "stub-$ASSERTIONS"; write_fixtures
    stub_gitleaks "$code" "$report"
    run_job
    expect_contains "stub $mode exit $code report [$report]: error" "$msg" "$OUT"
    expect_eq "stub $mode exit $code report [$report]: Scan failed" Scan "$FAILED"
    expect_eq "stub $mode exit $code report [$report]: job conclusion" failure "$JOB"
    expect_eq "stub $mode exit $code report [$report]: no findings output" "" "$(cat "$RT/output")"
  done
done

# 4n. A workspace path that cannot go into the TOML literal string is refused
# before any config is written.
for name in "quote'ws" $'nl\nws'; do
  reset_inputs; new_ws "$name"; write_fixtures
  caller_rule "$WS/.gitleaks.toml" yes
  run_job
  expect_contains "workspace [$name]: refused" "cannot be written into a TOML literal string" "$OUT"
  expect_eq "workspace [$name]: Write config failed" "$WRITE_STEP" "$FAILED"
  [ ! -e "$RT/fvh-gitleaks.toml" ] || fail "workspace [$name]: a config was written anyway"
  pass
done

# 4o. pull_request (#213): the caller's config and .gitleaksignore are read
# from the base commit, so a pull request cannot loosen its own scan. Each
# fixture is a merge commit laid out like refs/pull/N/merge: first parent the
# base, second the pull request's head.
ws_git() {
  git -C "$WS" -c user.name=fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"
}
commit_base() { # commits the tree as the base, then opens the PR branch
  ws_git add -A
  ws_git commit -q --allow-empty -m base
  ws_git switch -q -c pr
}
commit_merge() { # commits the tree as the PR head and merges it into the base
  ws_git add -A
  ws_git commit -q --allow-empty -m head
  ws_git switch -q -
  ws_git merge -q --no-ff -m merge pr
}
allowlist_config() { # file ; default rules, with docs/creds.ini allowlisted
  printf '[extend]\nuseDefault = true\n\n[[allowlists]]\npaths = [%s]\n' "'''docs/creds\\.ini\$'''" >"$1"
}
notice_config() { # config path
  printf '::notice file=%s::This pull request changes %s. The scan uses the base commit'"'"'s version; the change applies once merged.' "$1" "$1"
}
NOTICE_IGNORE="::notice file=.gitleaksignore::This pull request changes .gitleaksignore. The scan uses the base commit's version, and the pull request's version is not scanned; the change applies once merged."

# The defect: a pull request adds a secret and a config that allowlists it.
# Under push (the control) the allowlist applies; under pull_request it does not.
for event in push pull_request; do
  reset_inputs; EVENT=$event; new_ws "pr-allowlist-$event"
  echo "# fixture" >"$WS/README.md"
  commit_base
  write_fixtures
  allowlist_config "$WS/.gitleaks.toml"
  commit_merge
  run_job
  if [ "$event" = push ]; then
    expect_eq "pr-allowlist push control: the tree's allowlist applies" 0 "$(rule_count aws-access-token)"
    expect_absent "pr-allowlist push control: no base-commit notice" "::notice file=" "$OUT"
  else
    expect_eq "pr-allowlist: the PR's own allowlist does not apply" 1 "$(rule_count aws-access-token)"
    expect_eq "pr-allowlist: FVH rule fires" 2 "$(rule_count fvh-gcp-project-id)"
    expect_eq "pr-allowlist: job conclusion" failure "$JOB"
    expect_eq "pr-allowlist: only Enforce failed" Enforce "$FAILED"
    expect_contains "pr-allowlist: notice names the config" "$(notice_config .gitleaks.toml)" "$OUT"
    expect_contains "pr-allowlist: no config at the base, so the default rules run" "useDefault = true" "$(cat "$RT/fvh-gitleaks.toml")"
    expect_absent "pr-allowlist: the PR's config is not extended" "path = " "$(cat "$RT/fvh-gitleaks.toml")"
  fi
done

# A config the base commit already holds applies, unchanged, with no notice.
reset_inputs; EVENT=pull_request; new_ws pr-base-config
caller_rule "$WS/.gitleaks.toml" yes
commit_base
write_fixtures
echo "token: caller-secret-""123456" >"$WS/docs/app.txt"
commit_merge
run_job
expect_contains "pr-base-config: extends the base commit's copy" "path = '$RT/gitleaks-base/.gitleaks.toml'" "$(cat "$RT/fvh-gitleaks.toml")"
expect_eq "pr-base-config: the base config's rule fires" 1 "$(rule_count caller-token)"
expect_eq "pr-base-config: default rules through the base config's useDefault" 1 "$(rule_count aws-access-token)"
expect_absent "pr-base-config: no notice for an unchanged config" "::notice file=" "$OUT"

# A pull request that narrows the config (drops a rule and the default rules)
# is still scanned with the base commit's rules.
reset_inputs; EVENT=pull_request; new_ws pr-narrow
caller_rule "$WS/.gitleaks.toml" yes
commit_base
write_fixtures
echo "token: caller-secret-""123456" >"$WS/docs/app.txt"
printf 'title = "narrowed"\n' >"$WS/.gitleaks.toml"
commit_merge
run_job
expect_eq "pr-narrow: the dropped rule still fires" 1 "$(rule_count caller-token)"
expect_eq "pr-narrow: the default rules still run" 1 "$(rule_count aws-access-token)"
expect_contains "pr-narrow: notice names the config" "$(notice_config .gitleaks.toml)" "$OUT"
expect_absent "pr-narrow: the useDefault warning judges the base config, not the PR's" "useDefault = true, so" "$OUT"

# A pull request that deletes the config is scanned with the base commit's.
reset_inputs; EVENT=pull_request; new_ws pr-delete-config
caller_rule "$WS/.gitleaks.toml" yes
commit_base
echo "token: caller-secret-""123456" >"$WS/app.txt"
rm "$WS/.gitleaks.toml"
commit_merge
run_job
expect_eq "pr-delete-config: the base config's rule still fires" 1 "$(rule_count caller-token)"
expect_contains "pr-delete-config: notice names the config" "$(notice_config .gitleaks.toml)" "$OUT"

# .gitleaksignore: an entry the pull request adds does not silence its finding
# (control: under push it does), and an entry the base holds still applies.
for event in push pull_request; do
  reset_inputs; EVENT=$event; new_ws "pr-ignore-$event"
  mkdir -p "$WS/old"
  printf 'id: %s-legacy\n' "$fvh_prefix" >"$WS/old/legacy.md"
  echo "old/legacy.md:fvh-gcp-project-id:1" >"$WS/.gitleaksignore"
  commit_base
  mkdir -p "$WS/docs"
  printf 'aws_access_key_id = %s\n' "$aws_key" >"$WS/docs/creds.ini"
  echo "docs/creds.ini:aws-access-token:1" >>"$WS/.gitleaksignore"
  commit_merge
  run_job
  expect_eq "pr-ignore $event: the base commit's entry applies" 0 "$(rule_count fvh-gcp-project-id)"
  if [ "$event" = push ]; then
    expect_eq "pr-ignore push control: the tree's entry applies" 0 "$(rule_count aws-access-token)"
    expect_absent "pr-ignore push control: no base-commit notice" "::notice file=" "$OUT"
  else
    expect_eq "pr-ignore: the PR's own entry does not apply" 1 "$(rule_count aws-access-token)"
    expect_eq "pr-ignore: job conclusion" failure "$JOB"
    expect_contains "pr-ignore: notice names .gitleaksignore" "$NOTICE_IGNORE" "$OUT"
  fi
done
# A .gitleaksignore that only the pull request has is taken out of the scan.
reset_inputs; EVENT=pull_request; new_ws pr-ignore-new
echo "# fixture" >"$WS/README.md"
commit_base
mkdir -p "$WS/docs"
printf 'aws_access_key_id = %s\n' "$aws_key" >"$WS/docs/creds.ini"
echo "docs/creds.ini:aws-access-token:1" >"$WS/.gitleaksignore"
commit_merge
run_job
expect_eq "pr-ignore-new: the PR's new ignore file does not apply" 1 "$(rule_count aws-access-token)"
expect_contains "pr-ignore-new: notice names .gitleaksignore" "$NOTICE_IGNORE" "$OUT"
# An unchanged .gitleaksignore gets no notice.
reset_inputs; EVENT=pull_request; new_ws pr-ignore-same
echo "old/legacy.md:fvh-gcp-project-id:1" >"$WS/.gitleaksignore"
commit_base
echo "# change" >"$WS/README.md"
commit_merge
run_job
expect_eq "pr-ignore-same: job conclusion" success "$JOB"
expect_absent "pr-ignore-same: no notice" "::notice file=" "$OUT"

# A non-default config-path that the pull request introduces is not an error:
# the base has none, so the default rules run and the notice says so. One that
# neither commit holds still is.
reset_inputs; EVENT=pull_request; INPUT[config-path]=config/gitleaks.toml; new_ws pr-custom-new
echo "# fixture" >"$WS/README.md"
commit_base
write_fixtures
mkdir -p "$WS/config"; allowlist_config "$WS/config/gitleaks.toml"
commit_merge
run_job
expect_eq "pr-custom-new: the PR's allowlist does not apply" 1 "$(rule_count aws-access-token)"
expect_contains "pr-custom-new: notice names the config" "$(notice_config config/gitleaks.toml)" "$OUT"
expect_eq "pr-custom-new: only Enforce failed" Enforce "$FAILED"
reset_inputs; EVENT=pull_request; INPUT[config-path]=config/gitleaks.toml; new_ws pr-custom-missing
echo "# fixture" >"$WS/README.md"
commit_base
write_fixtures
commit_merge
run_job
expect_contains "pr-custom-missing: error names the path" "::error::config-path 'config/gitleaks.toml'" "$OUT"
expect_eq "pr-custom-missing: Write config failed" "$WRITE_STEP" "$FAILED"

# gitleaks resolves a nested [extend] path against the working directory, so
# the file it names would come from the pull request. Unchanged, the scan
# runs (with the nested-extend warning); changed, the run fails before any
# scan.
for change in same changed; do
  reset_inputs; EVENT=pull_request; new_ws "pr-nested-$change"
  printf '[extend]\npath = "base.toml"\n' >"$WS/.gitleaks.toml"
  caller_rule "$WS/base.toml" yes
  commit_base
  echo "token: caller-secret-""123456" >"$WS/app.txt"
  if [ "$change" = changed ]; then printf 'title = "emptied"\n' >"$WS/base.toml"; fi
  commit_merge
  run_job
  if [ "$change" = same ]; then
    expect_eq "pr-nested-same: the nested file's rule fires" 1 "$(rule_count caller-token)"
    expect_contains "pr-nested-same: nested-extend warning" "::warning file=.gitleaks.toml::.gitleaks.toml extends another file." "$OUT"
  else
    expect_contains "pr-nested-changed: error" "::error file=.gitleaks.toml::.gitleaks.toml extends a file that this pull request changes." "$OUT"
    expect_eq "pr-nested-changed: Write config failed" "$WRITE_STEP" "$FAILED"
    expect_eq "pr-nested-changed: job conclusion" failure "$JOB"
    [ ! -e "$RT/gitleaks.json" ] || fail "pr-nested-changed: the scan ran anyway"
    pass
  fi
done

# A pull_request run whose HEAD is not a merge commit has no base commit to
# read from: it fails rather than fall back to the checkout's config.
reset_inputs; EVENT=pull_request; new_ws pr-no-merge; write_fixtures
allowlist_config "$WS/.gitleaks.toml"
ws_git add -A; ws_git commit -q -m only
run_job
expect_contains "pr-no-merge: error" "::error::This is a pull_request run, but HEAD is not a merge commit" "$OUT"
expect_eq "pr-no-merge: Write config failed" "$WRITE_STEP" "$FAILED"
[ ! -e "$RT/fvh-gitleaks.toml" ] || fail "pr-no-merge: a config was written anyway"
pass

# ---------------------------------------------------------------------------
# 5. Starter template
# ---------------------------------------------------------------------------
[ -f "$TPL" ] || fail "$TPL does not exist"
[ -f "${TPL%.yml}.properties.json" ] || fail "${TPL%.yml}.properties.json does not exist"
expect_eq "template calls the reusable at @main" \
  "ForumViriumHelsinki/.github/.github/workflows/reusable-gitleaks.yml@main" "$(yq '.jobs[].uses' "$TPL")"
expect_eq "template permissions" '{"contents":"read"}' "$(yq -o=json -I0 '.permissions' "$TPL")"
expect_eq "template triggers" '["pull_request","push"]' "$(yq -o=json -I0 '.on | keys' "$TPL")"
expect_eq "template push branch" '$default-branch' "$(yq '.on.push.branches[0]' "$TPL")"
expect_eq "template category" Security "$(jq -r '.categories[0]' "${TPL%.yml}.properties.json")"

echo "PASS: ${NAME} (${ASSERTIONS} assertion(s))"
