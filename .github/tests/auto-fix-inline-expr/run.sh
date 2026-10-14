#!/usr/bin/env bash
# auto-fix-inline-expr — no `${{ }}` expression inside a run: body of
# reusable-auto-fix.yml.
#
# GitHub pastes an expression's value into the script text before bash parses
# it. Callers pass `branch: ${{ github.event.workflow_run.head_branch }}`, and a
# fork PR author chooses that name: a branch called `x";touch pwned;B="` closes
# the quote in `BRANCH="${{ inputs.branch }}"` and runs with this job's
# contents/pull-requests/issues write and id-token: write. Caller-controlled
# values are bound in the step's env: block and read as quoted shell variables.
#
# Three checks:
#   1. every run: body in the job contains no `${{`, walked by step index (a
#      by-name lookup would read an unnamed step's body as '' and pass it),
#      one assertion per step so a failure names the step;
#   2. the env: bindings that replace the inline expressions exist;
#   3. the shipped 'Gather failure context' body, rendered the way GitHub
#      renders it (expressions in run: and env: substituted as text), runs
#      against stub gh with a hostile branch name: the payload must not
#      execute and the name must reach gh verbatim.
#
# Scope: this workflow only. Other reusable workflows still have `${{ }}` in
# run: bodies; most of those carry values the caller does not take from an
# event payload, and each needs its own review before a class-wide scan.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME=auto-fix-inline-expr
WORKFLOW=.github/workflows/reusable-auto-fix.yml
JOB=auto-fix

command -v yq >/dev/null || { echo "FAIL: $NAME: yq not found on PATH"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: $NAME: python3 not found on PATH"; exit 1; }

assertions=0
failures=0
check() { # <condition-exit-status> <message>
  assertions=$((assertions + 1))
  if [ "$1" -ne 0 ]; then
    failures=$((failures + 1))
    echo "FAIL: $NAME: $2"
  fi
}
step_q() { # <index> <yq path under the step>
  I="$1" yq -r ".jobs[\"$JOB\"].steps[env(I)]$2" "$WORKFLOW"
}

# ---------------------------------------------------------------- 1. run bodies
step_count="$(yq -r ".jobs[\"$JOB\"].steps | length" "$WORKFLOW")"
[ "$step_count" -gt 0 ] || { echo "FAIL: $NAME: job '$JOB' has no steps in $WORKFLOW (scan broken)"; exit 1; }
run_seen=0
for ((i = 0; i < step_count; i++)); do
  [ "$(step_q "$i" ' | has("run")')" = true ] || continue
  run_seen=$((run_seen + 1))
  label="$(step_q "$i" '.name // "step #" + strenv(I)')"
  body="$(step_q "$i" '.run')"
  rc=0
  # shellcheck disable=SC2016 # a literal GitHub expression, not a shell one
  grep -Fq '${{' <<<"$body" && rc=1
  check "$rc" "'$label' run: body contains \${{ }}; bind the value in env: and read it as a quoted shell variable"
done
rc=0; [ "$run_seen" -gt 0 ] || rc=1
check "$rc" "found no run: steps in job '$JOB' (scan broken)"

# ---------------------------------------------------------------- 2. env wiring
index_of() { # <step id>
  ID="$1" yq -r ".jobs[\"$JOB\"].steps | to_entries | map(select(.value.id == strenv(ID))) | .[0].key // \"\"" "$WORKFLOW"
}
while IFS='|' read -r id key want; do
  idx="$(index_of "$id")"
  if [ -z "$idx" ]; then
    check 1 "no step with id '$id'"
    continue
  fi
  got="$(step_q "$idx" ".env.$key // \"\"")"
  rc=0; [ "$got" = "$want" ] || rc=1
  check "$rc" "step '$id' env $key: got '$got', want '$want'"
done <<'WIRING'
context|RUN_ID|${{ inputs.run_id }}
context|BRANCH|${{ inputs.branch }}
context|PR_NUMBER_INPUT|${{ inputs.pr_number }}
dedup|MAX_PRS|${{ inputs.max_auto_fix_prs }}
WIRING

# ------------------------------------------------- 3. hostile branch, executed
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ctx_idx="$(index_of context)"
if [ -z "$ctx_idx" ]; then
  check 1 "no step with id 'context' to execute"
else
  step_q "$ctx_idx" '.run' > "$tmp/body.tmpl"
  I="$ctx_idx" yq -o=json ".jobs[\"$JOB\"].steps[env(I)].env // {}" "$WORKFLOW" > "$tmp/env.json"

  mkdir -p "$tmp/bin" "$tmp/repo"
  cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Sentinel the real gh never prints, so a stub that did not run is visible.
printf 'STUB-GH-CALLED' >> "$STUB_GH_LOG"
for a in "$@"; do printf '\t%s' "$a" >> "$STUB_GH_LOG"; done
printf '\n' >> "$STUB_GH_LOG"
STUB
  chmod +x "$tmp/bin/gh"
  git -C "$tmp/repo" init -q
  git -C "$tmp/repo" -c core.hooksPath=/dev/null -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init

  # The payload closes the double quote of an inline `BRANCH="${{ ... }}"` and
  # touches $PWNED. As an env value read as "$BRANCH" it is inert text.
  # shellcheck disable=SC2016 # literal payload; must not expand here
  hostile='x";touch "$PWNED";B="'
  rc=0
  HOSTILE="$hostile" TMP="$tmp" python3 - <<'PY' || rc=$?
import json, os, re, subprocess, sys

tmp, hostile = os.environ["TMP"], os.environ["HOSTILE"]
values = {
    "inputs.branch": hostile,
    "inputs.run_id": "12345",
    "inputs.pr_number": "",
    "secrets.GITHUB_TOKEN": "stub-token",
    "runner.temp": tmp,
}
EXPR = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")


def render(text):
    def sub(m):
        if m.group(1) not in values:
            sys.exit(f"render: no test value for expression '{m.group(1)}'; add one to the test")
        return values[m.group(1)]
    return EXPR.sub(sub, text)


body = render(open(f"{tmp}/body.tmpl").read())
open(f"{tmp}/body.sh", "w").write(body)
env = {k: render(str(v)) for k, v in json.load(open(f"{tmp}/env.json")).items()}
env.update({
    "PATH": f"{tmp}/bin:{os.environ['PATH']}",
    "HOME": tmp,
    "GITHUB_OUTPUT": f"{tmp}/github_output",
    "STUB_GH_LOG": f"{tmp}/gh.log",
    "PWNED": f"{tmp}/pwned",
})
# GitHub runs a run: step with no shell: as `bash -e {0}`.
proc = subprocess.run(["bash", "-e", f"{tmp}/body.sh"], cwd=f"{tmp}/repo", env=env,
                      capture_output=True, text=True)
open(f"{tmp}/step.out", "w").write(proc.stdout + proc.stderr)
sys.exit(proc.returncode)
PY
  check "$rc" "rendered 'Gather failure context' body exited $rc: $(cat "$tmp/step.out" 2>/dev/null || true)"

  rc=0; [ ! -e "$tmp/pwned" ] || rc=1
  check "$rc" "hostile branch name executed as shell code in 'Gather failure context' (\$PWNED was created)"

  gh_log="$(cat "$tmp/gh.log" 2>/dev/null || true)"
  rc=0; grep -Fq 'STUB-GH-CALLED' <<<"$gh_log" || rc=1
  check "$rc" "stub gh never ran; the step may have called a real gh or stopped early"

  rc=0; grep -Fq -- "$(printf -- '--head\t%s' "$hostile")" <<<"$gh_log" || rc=1
  check "$rc" "branch name did not reach 'gh pr list --head' verbatim; gh log: $gh_log"

  out="$(cat "$tmp/github_output" 2>/dev/null || true)"
  rc=0; grep -Fqx 'pr_number=' <<<"$out" || rc=1
  check "$rc" "step did not write pr_number to GITHUB_OUTPUT; got: $out"
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $NAME ($failures of $assertions assertion(s) failed)"
  exit 1
fi
echo "PASS: $NAME ($assertions assertion(s))"
