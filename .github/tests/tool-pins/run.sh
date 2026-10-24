#!/usr/bin/env bash
# tool-pins — every lint toolchain version is pinned exactly, agrees across the
# files that use it, and is tracked by a Renovate regex manager that really
# matches it (#141, #182).
#
#   rulesync    every npx/bunx/pnpx invocation in the workflows, starter
#               templates, justfile, docs, scripts and tests carries @X.Y.Z (or
#               the justfile's {{ rulesync_version }}); no @latest, no bare
#               name; one version everywhere. A floating rulesync turned lint
#               red with no change here (#126), and consumers run the reusable
#               sync workflow at @main.
#   actionlint, gitleaks, ruff
#               every <TOOL>_VERSION env in a workflow equals the justfile's
#               <tool>_version, and is X.Y.Z; every <TOOL>_SHA256 is 64 hex
#               characters and agrees across workflows. A step that downloads
#               a tool's release asset must carry both env pins, so a copied
#               install (reusable-gitleaks.yml's, #149) cannot hard-code a
#               version that neither the agreement check nor Renovate sees.
#   renovate.json
#               every regex customManager's matchStrings, converted from
#               Renovate's (?<name>) to Python's (?P<name>), match at least once
#               in the files its managerFilePatterns select, and capture exactly
#               the pinned version; every pin site found above is captured by
#               some manager, so a regex that silently stops matching, or a new
#               file the patterns miss, fails here instead of going stale.
#
# Usage: run.sh [ROOT]   (default: the repo root; the teeth check runs it on a
#                         scratch copy with one pin broken)
set -euo pipefail
cd "${1:-$(git rev-parse --show-toplevel)}"

command -v yq >/dev/null || { echo "FAIL: tool-pins: yq not found on PATH"; exit 1; }

python3 - <<'PY'
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys

NAME = "tool-pins"
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")
failures, assertions = [], 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def yq(expr, path):
    return subprocess.run(["yq", expr, path], check=True, capture_output=True, text=True).stdout


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


workflows = sorted(glob.glob(".github/workflows/*.yml") + glob.glob(".github/workflows/*.yaml"))
templates = sorted(glob.glob("workflow-templates/*.yml") + glob.glob("workflow-templates/*.yaml"))
check(workflows, "found no .github/workflows/*.yml files")
justfile = read("justfile")


def just_var(name):
    m = re.search(rf'^{name}\s*:=\s*"([^"]*)"\s*$', justfile, re.M)
    return (m.group(1), lineno(justfile, m.start())) if m else (None, None)


# ---------------------------------------------------------------- rulesync
# A rulesync run through a package runner. The version (if any) is the @...
# suffix; `npx rulesync:*`-style permission patterns have no whitespace after
# the name and are not runs.
RUNNER = re.compile(
    r"\b(?:npx|bunx|pnpx|dlx)\b(?:\s+-{1,2}[\w-]+)*\s+[\"']?rulesync"
    r"(?:@(?P<ver>\{\{\s*\w+\s*\}\}|[^\s`'\")]+))?(?=\s|$|[`'\")])"
)
scan = sorted(set(
    workflows + templates
    + ["justfile", "README.md", "CLAUDE.md", "DEVELOPERS.md", ".pre-commit-config.yaml"]
    + glob.glob("scripts/*") + glob.glob(".github/tests/*/run.sh") + glob.glob(".github/tests/README.md")
))
scan = [p for p in scan if os.path.isfile(p)]
rs_var, rs_var_line = just_var("rulesync_version")
rulesync_sites = []  # (path, line, version)
for path in scan:
    text = read(path)
    for m in RUNNER.finditer(text):
        ver, where = m.group("ver"), f"{path}:{lineno(text, m.start())}"
        if ver is None:
            failures.append(f"{where}: unpinned rulesync run `{m.group(0).strip()}`; pin rulesync@X.Y.Z")
            continue
        if path == "justfile" and re.fullmatch(r"\{\{\s*rulesync_version\s*\}\}", ver):
            check(rs_var is not None, f"{where}: uses {{{{ rulesync_version }}}} but the justfile defines no rulesync_version")
            if rs_var is None:
                continue
            rulesync_sites.append((path, rs_var_line, rs_var))
            continue
        assertions += 1
        if not SEMVER.match(ver):
            failures.append(f"{where}: rulesync@{ver} is not an exact X.Y.Z version")
            continue
        rulesync_sites.append((path, lineno(text, m.start()), ver))

# A direct `rulesync fetch|generate` (no runner) inside a workflow run: body
# or the justfile would resolve whatever is on PATH.
DIRECT = re.compile(r"(?:^|[\s;&|(])rulesync(?:@\S+)?\s+(?:fetch|generate)\b")
for path in workflows + templates + ["justfile"]:
    for no, line in enumerate(read(path).splitlines(), 1):
        if line.lstrip().startswith("#"):
            continue
        for m in DIRECT.finditer(line):
            check(RUNNER.search(line[: m.end()]) is not None,
                  f"{path}:{no}: `rulesync` run without npx and a pinned version: {line.strip()}")

for must in (".github/workflows/lint.yml", ".github/workflows/reusable-sync-ai-rules.yml", "justfile"):
    check(any(p == must for p, _, _ in rulesync_sites), f"found no pinned rulesync run in {must}")
rs_versions = sorted({v for _, _, v in rulesync_sites})
check(len(rs_versions) == 1,
      f"expected one rulesync version everywhere, found {rs_versions}: "
      + ", ".join(f"{p}:{n}={v}" for p, n, v in sorted(set(rulesync_sites))))
pins = {"rulesync": rs_versions[0] if len(rs_versions) == 1 else None}
sites = {"rulesync": {(p, n) for p, n, _ in rulesync_sites}}

# ----------------------------------------------- checksum-pinned binaries
TOOLS = {"actionlint": "rhysd/actionlint", "gitleaks": "gitleaks/gitleaks", "ruff": "astral-sh/ruff"}
DEPNAME = {"rulesync": "rulesync", **TOOLS}
for tool in TOOLS:
    key = tool.upper()
    jv, jline = just_var(f"{tool}_version")
    check(jv is not None and SEMVER.match(jv or ""), f"justfile: {tool}_version := \"X.Y.Z\" missing or not exact (got {jv!r})")
    pins[tool] = jv
    sites[tool] = {("justfile", jline)} if jline else set()
    shas = {}
    for path in workflows:
        text = read(path)
        for m in re.finditer(rf"^[ \t]*{key}_VERSION:[ \t]*(\S+)[ \t]*$", text, re.M):
            v = m.group(1).strip("'\"")
            sites[tool].add((path, lineno(text, m.start())))
            check(SEMVER.match(v), f"{path}:{lineno(text, m.start())}: {key}_VERSION {v!r} is not an exact X.Y.Z version")
            check(v == jv, f"{path}:{lineno(text, m.start())}: {key}_VERSION {v} != justfile {tool}_version {jv}")
        for m in re.finditer(rf"^[ \t]*{key}_SHA256:[ \t]*(\S+)[ \t]*$", text, re.M):
            s = m.group(1).strip("'\"")
            check(re.fullmatch(r"[0-9a-f]{64}", s), f"{path}:{lineno(text, m.start())}: {key}_SHA256 is not 64 lowercase hex characters")
            shas.setdefault(s, []).append(f"{path}:{lineno(text, m.start())}")
    check(any(p == ".github/workflows/lint.yml" for p, _ in sites[tool]), f".github/workflows/lint.yml has no {key}_VERSION")
    check(len(shas) == 1, f"{key}_SHA256 is missing or differs between workflows: {shas}")
    # The step that downloads the binary must check it.
    for path in workflows:
        body = yq(f'[.jobs[].steps[] | select(.env.{key}_VERSION != null) | .run] | join("\\n---\\n")', path)
        if body.strip():
            check(f"${{{key}_SHA256}}" in body and "sha256sum -c" in body,
                  f"{path}: the step with {key}_VERSION does not verify ${{{key}_SHA256}} with sha256sum -c")
    # Every step that downloads the release asset is pinned through env.
    download = f"github.com/{TOOLS[tool]}/releases/download/"
    for path in workflows:
        unpinned = yq(
            f'[.jobs[].steps[] | select(.run // "" | contains("{download}"))'
            f' | select(.env.{key}_VERSION == null or .env.{key}_SHA256 == null) | .name // "(unnamed)"]'
            ' | join(", ")', path).strip()
        check(not unpinned, f"{path}: step(s) {unpinned} download {download} without {key}_VERSION and {key}_SHA256 env pins")

# ------------------------------------------------------------ renovate.json
try:
    renovate = json.loads(read("renovate.json"))
except (OSError, ValueError) as err:
    failures.append(f"renovate.json: {err}")
    renovate = {}
managers = [m for m in renovate.get("customManagers", []) if m.get("customType") == "regex"]
check(managers, "renovate.json has no regex customManagers")
ls = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
if ls.returncode == 0:
    tracked = [f for f in ls.stdout.split("\0") if f]
else:  # a scratch copy that is not a git checkout
    tracked = [os.path.relpath(os.path.join(d, f)) for d, dirs, fs in os.walk(".")
               for f in fs if not (dirs.__setitem__(slice(None), [x for x in dirs if x not in (".git", "node_modules")]))]


def select(patterns):
    out = set()
    for pat in patterns:
        if len(pat) > 1 and pat.startswith("/") and pat.endswith("/"):
            rx = re.compile(pat[1:-1])
            out |= {f for f in tracked if rx.search(f)}
        else:  # minimatch glob; `*` does not cross `/`, as with glob.glob
            out |= {f for f in tracked if fnmatch.fnmatch(f, pat) and f.count("/") == pat.count("/")}
    return sorted(f for f in out if os.path.isfile(f))


captured = {t: set() for t in DEPNAME}
seen_deps = set()
for i, mgr in enumerate(managers):
    dep = mgr.get("depNameTemplate")
    tool = next((t for t, d in DEPNAME.items() if d == dep), None)
    where = f"renovate.json customManagers[{i}] ({dep})"
    check(tool is not None, f"{where}: depNameTemplate {dep!r} is not one of {sorted(DEPNAME.values())}; extend this test")
    if tool is None:
        continue
    seen_deps.add(tool)
    want_ds = "npm" if tool == "rulesync" else "github-releases"
    check(mgr.get("datasourceTemplate") == want_ds, f"{where}: datasourceTemplate {mgr.get('datasourceTemplate')!r} != {want_ds}")
    patterns = mgr.get("managerFilePatterns") or mgr.get("fileMatch") or []
    files = select(patterns)
    check(files, f"{where}: managerFilePatterns {patterns} select no files")
    for ms in mgr.get("matchStrings", []):
        try:
            rx = re.compile(ms.replace("(?<", "(?P<"), re.M)
        except re.error as err:
            failures.append(f"{where}: matchString {ms!r} does not compile: {err}")
            continue
        hits = 0
        for path in files:
            text = read(path)
            for m in rx.finditer(text):
                hits += 1
                got = m.groupdict().get("currentValue")
                check(got == pins.get(tool),
                      f"{where}: matchString {ms!r} captured {got!r} in {path}:{lineno(text, m.start())}, pinned version is {pins.get(tool)!r}")
                captured[tool].add((path, lineno(text, m.start("currentValue") if got is not None else m.start())))
        check(hits > 0, f"{where}: matchString {ms!r} matches nothing in the {len(files)} file(s) its managerFilePatterns select")

for tool in DEPNAME:
    check(tool in seen_deps, f"renovate.json has no regex customManager for {DEPNAME[tool]}")
    missed = sorted(sites[tool] - captured[tool])
    check(not missed, f"{tool} pin site(s) no renovate customManager captures, so a bump would skip them: "
          + ", ".join(f"{p}:{n}" for p, n in missed))

rules = renovate.get("packageRules", [])


def rules_for(dep):
    return [r for r in rules if dep in r.get("matchDepNames", [])]


rs_rules = rules_for("rulesync")
check(any(r.get("minimumReleaseAge") for r in rs_rules), "renovate.json: no packageRule gives rulesync a minimumReleaseAge")
check(any(r.get("schedule") for r in rs_rules), "renovate.json: no packageRule gives rulesync a schedule")
for tool, dep in TOOLS.items():
    rs = rules_for(dep)
    check(any(r.get("groupName") for r in rs), f"renovate.json: no packageRule groups {dep}'s files into one PR")
    check(any(f"{tool.upper()}_SHA256" in " ".join(r.get("prBodyNotes", [])) for r in rs),
          f"renovate.json: no prBodyNotes on {dep} saying the checksum must be bumped by hand")

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}", file=sys.stderr)
    sys.exit(1)
print("pins: " + ", ".join(f"{t} {v}" for t, v in pins.items()))
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY
