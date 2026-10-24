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
reset_inputs() {
  INPUT=()
  local k
  for k in $(yq '.on.workflow_call.inputs | keys | .[]' "$WF"); do
    INPUT[$k]=$(K="$k" yq '.on.workflow_call.inputs[strenv(K)].default' "$WF")
  done
}

# Runs one shipped step in $WS. Env values that are `${{ inputs.X }}` take
# INPUT[X], `${{ steps.<id>.outputs.<key> }}` the last `<key>=` line in the
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
