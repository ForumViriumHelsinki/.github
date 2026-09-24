#!/usr/bin/env bash
# Fails on any pipe into `grep -q` that runs under `pipefail`.
#
# `grep -q` exits on its first match and closes the pipe. If the producer is
# still writing, its write fails with EPIPE ("Broken pipe") and it exits
# non-zero. Without pipefail the pipeline takes grep's status (0) and nothing
# happens; with pipefail it takes the producer's, so a line that DID match
# reports failure. Whether the producer finishes first is timing: #136's bun-ci
# test passed on macOS and failed on ubuntu-slim with
# `printf: write error: Broken pipe` followed by a false "not documented".
#
# Fix a flagged line by removing the second process, not by adding `|| true`:
#   grep -Fq "$needle" <<<"$haystack"           # variable input: here-string
#   grep -Fq "$needle" <<<"$(some_command)"     # command input
#   some_command | grep -F "$needle" >/dev/null # reads to EOF, so no early exit
#
# Where pipefail applies:
#   - a shell file (.github/tests/**, scripts/**) that runs `set ... -o pipefail`
#     (which includes `set -euo pipefail`);
#   - a workflow `run:` step whose effective shell is exactly `bash`
#     (step `shell:`, else job `defaults.run.shell`, else workflow
#     `defaults.run.shell`). GitHub runs that as
#     `bash --noprofile --norc -eo pipefail {0}`; a step with no shell runs
#     `bash -e {0}`, without pipefail (docs.github.com, workflow syntax,
#     jobs.<job_id>.steps[*].shell). A custom shell string counts when it
#     names pipefail, and any body that sets pipefail itself counts.
#
# Only `grep` with -q/--quiet/--silent is checked. `| head` has the same
# mechanism but is usually deliberate truncation, so it is out of scope.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: pipefail-grep-q: yq not found on PATH"; exit 1; }

python3 - <<'PY'
import glob
import json
import re
import subprocess
import sys

NAME = "pipefail-grep-q"
failures = []
assertions = 0


def check(ok, msg):
    global assertions
    assertions += 1
    if not ok:
        failures.append(msg)


# A single `|` (not `||`) followed by grep and its arguments up to the next
# pipe or command separator.
PIPE_GREP = re.compile(r"(?<!\|)\|(?!\|)\s*grep\b([^|;&]*)")
SETS_PIPEFAIL = re.compile(r"\bset\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*o\s+pipefail\b")


def quiet_grep(args):
    for tok in args.split():
        if tok in ("--quiet", "--silent"):
            return True
        if re.fullmatch(r"-[A-Za-z]+", tok) and "q" in tok:
            return True
    return False


def logical_lines(text):
    """Yield (first_lineno, line) with backslash continuations joined and
    comment-only lines skipped."""
    buf, start = "", None
    for n, raw in enumerate(text.splitlines(), 1):
        if not buf and raw.lstrip().startswith("#"):
            continue
        if start is None:
            start = n
        if raw.rstrip().endswith("\\"):
            buf += raw.rstrip()[:-1] + " "
            continue
        yield start, buf + raw
        buf, start = "", None
    if buf:
        yield start, buf


def offenders(text):
    return [(n, line.strip()) for n, line in logical_lines(text)
            if any(quiet_grep(m.group(1)) for m in PIPE_GREP.finditer(line))]


def effective_pipefail(step, job, wf):
    shell = step.get("shell") \
        or ((job.get("defaults") or {}).get("run") or {}).get("shell") \
        or ((wf.get("defaults") or {}).get("run") or {}).get("shell")
    if shell == "bash" or (isinstance(shell, str) and "pipefail" in shell):
        return True
    return bool(SETS_PIPEFAIL.search(step.get("run", "")))


# ---- Controls: the detector must find what it claims to find. Fixtures are
# assembled from parts so this file does not match its own scan.
BAR, G = "|", "grep"
bad = [
    f"printf '%s\\n' \"$x\" {BAR} {G} -Fq \"y\" || fail",
    f"cmd {BAR} {G} -q -F y",
    f"a {BAR}{G} --quiet b",
    f"a \\\n  {BAR} {G} -qs b",
]
good = [
    f"{G} -Fq \"y\" <<<\"$x\"",
    f"a {BAR}{BAR} {G} -q b",
    f"{G} -q x file",
    f"a {BAR} {G} x >/dev/null",
    f"  # a {BAR} {G} -q b in a comment",
]
for s in bad:
    check(len(offenders(s)) == 1, f"control: detector missed {s!r}")
for s in good:
    check(offenders(s) == [], f"control: detector flagged {s!r}")

step_default = {"run": "true"}
check(not effective_pipefail(step_default, {}, {}), "control: an unspecified shell is `bash -e`, not pipefail")
check(effective_pipefail({"run": "true", "shell": "bash"}, {}, {}), "control: `shell: bash` is pipefail")
check(effective_pipefail(step_default, {"defaults": {"run": {"shell": "bash"}}}, {}), "control: job defaults.run.shell bash is pipefail")
check(effective_pipefail(step_default, {}, {"defaults": {"run": {"shell": "bash"}}}), "control: workflow defaults.run.shell bash is pipefail")
check(effective_pipefail({"run": "set -euo pipefail\ntrue"}, {}, {}), "control: a body that sets pipefail is pipefail")
check(not effective_pipefail({"run": "true", "shell": "sh"}, {}, {}), "control: `shell: sh` is not pipefail")

# ---- Shell files
shell_files = sorted(set(glob.glob(".github/tests/**/*.sh", recursive=True)
                         + glob.glob("scripts/**/*.sh", recursive=True)))
pipefail_files = 0
for path in shell_files:
    text = open(path, encoding="utf-8").read()
    if not SETS_PIPEFAIL.search(text):
        continue
    pipefail_files += 1
    for n, line in offenders(text):
        check(False, f"{path}:{n}: pipe into grep -q under pipefail: {line}")
check(pipefail_files > 0, "found no shell file that sets pipefail (scan broken)")

# ---- Workflow run: bodies
workflows = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml")
                   + glob.glob("workflow-templates/*.yml") + glob.glob("workflow-templates/*.yaml"))
check(len(workflows) > 0, "found no workflow files (scan broken)")
run_bodies = pipefail_bodies = 0
for path in workflows:
    wf = json.loads(subprocess.check_output(["yq", "-o=json", ".", path]))
    for job_id, job in (wf.get("jobs") or {}).items():
        for i, step in enumerate(job.get("steps") or []):
            body = step.get("run")
            if not isinstance(body, str):
                continue
            run_bodies += 1
            if not effective_pipefail(step, job, wf):
                continue
            pipefail_bodies += 1
            label = step.get("name") or step.get("id") or f"step {i}"
            for n, line in offenders(body):
                check(False, f"{path}: job {job_id}, step '{label}', body line {n}: "
                             f"pipe into grep -q under pipefail: {line}")
check(run_bodies > 0, "found no workflow run: bodies (scan broken)")
check(pipefail_bodies > 0, "found no workflow run: body that runs under pipefail (scan broken)")

print(f"scanned {pipefail_files} pipefail shell file(s) of {len(shell_files)}, "
      f"{pipefail_bodies} pipefail run: bod(ies) of {run_bodies}")
if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}")
    print("Fix: grep -Fq \"$needle\" <<<\"$haystack\", or send the pipe to `grep ... >/dev/null`, which reads to EOF.")
    print(f"FAIL: {NAME} ({len(failures)} of {assertions} assertion(s) failed)")
    sys.exit(1)
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY
