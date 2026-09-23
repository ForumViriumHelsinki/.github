#!/usr/bin/env bash
# workflow-doc-tables — the reusable-workflow input tables in the org CI/CD
# rule must match the workflow_call contract they describe.
#
# Source of truth: `.on.workflow_call` in .github/workflows/reusable-*.yml,
# read with yq (ubuntu-slim ships yq; it does not ship PyYAML).
# Documentation under test: the rulesync source of the CI/CD rule. The four
# generated copies are covered by `npx rulesync generate --check`, which no CI
# workflow in this repo runs yet; until one does, a hand edit to a generated
# copy is not caught.
#
# Only names, types and defaults are checked. Prose describing a value (e.g.
# what an output holds when it is not set) is not.
#
# For every `### <Name> Workflow Inputs` section (mapped to its workflow file by
# SECTION_MAP below) the test asserts:
#   - every declared input has a row, with the declared type and default
#     (quotes and backticks normalised; `''` == empty == no default);
#   - every row names a declared input (catches renamed or removed inputs);
#   - every declared secret has a bullet under `Secrets:`, and every bullet
#     names a declared secret;
#   - every declared output has a bullet under `Outputs:`, and every bullet
#     names a declared output.
# It also checks every caller of a reusable workflow that the rule's YAML
# examples and workflow-templates/*.yml show: each `with:` / `secrets:` key must
# be declared by the called workflow.
#
# Deliberate scope choice: reusable workflows with no inputs section in the rule
# are listed as a NOTICE and do not fail the run. Documenting them is a separate
# decision (issue #112 follow-up); once a section is added and mapped here, it
# is enforced like the others.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v yq >/dev/null || { echo "FAIL: workflow-doc-tables: yq not found on PATH"; exit 1; }

python3 - <<'PY'
import glob, json, os, re, subprocess, sys

DOC = ".rulesync/rules/ci-cd-workflows.md"
NAME = "workflow-doc-tables"

# Section heading prefix -> workflow file. A `### ... Workflow Inputs` heading
# missing from this map fails the run, so a new section cannot go unchecked.
SECTION_MAP = {
    "Release-Please Workflow Inputs": "reusable-release-please.yml",
    "Renovate Workflow Inputs": "reusable-renovate.yml",
    "Claude Workflow Inputs": "reusable-claude.yml",
    "npm Publish Workflow Inputs": "reusable-npm-publish.yml",
}

# A default longer than this may be documented as "see workflow" instead of
# being copied into a rule that is loaded into every consumer's context.
LONG_DEFAULT = 80

failures = []
assertions = 0


def check(ok, msg):
    global assertions
    assertions += 1
    if not ok:
        failures.append(msg)


def read_doc():
    try:
        with open(DOC, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        # Local agent sessions may deny direct reads of the rulesync source;
        # the committed copy is the same file for a clean tree.
        return subprocess.run(["git", "show", "HEAD:" + DOC], check=True,
                              capture_output=True, text=True).stdout


def yq_json(expr, path):
    out = subprocess.run(["yq", "-o=json", expr, path], check=True,
                         capture_output=True, text=True).stdout
    return json.loads(out)


def contract(wf):
    call = yq_json(".on.workflow_call // {}", f".github/workflows/{wf}") or {}
    return (call.get("inputs") or {}, call.get("secrets") or {},
            call.get("outputs") or {})


def norm(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    s = str(value).strip()
    if len(s) >= 2 and s[0] == s[-1] == "`":
        s = s[1:-1]
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "'\"":
        s = s[1:-1]
    return s


def sections(doc):
    """Yield (heading, body) for each `### ... Workflow Inputs` section.

    A section runs until the next `## ` heading or the next `### ... Workflow
    Inputs` heading, so sub-headings inside it (e.g. the release-please warning)
    stay attributed to it.
    """
    lines = doc.splitlines()
    starts = [i for i, l in enumerate(lines)
              if l.startswith("### ") and "Workflow Inputs" in l]
    for n, i in enumerate(starts):
        end = len(lines)
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("## ") or j in starts[n + 1:]:
                end = j
                break
        yield lines[i][4:].strip(), lines[i + 1:end]


ROW = re.compile(r"^\|\s*`([^`]+)`\s*\|\s*([a-z]+)\s*\|\s*(.*?)\s*\|")


def input_rows(body):
    rows, in_table = {}, False
    for line in body:
        if re.match(r"^\|\s*Input\s*\|\s*Type\s*\|\s*Default\s*\|", line):
            in_table = True
            continue
        if in_table:
            if not line.startswith("|"):
                in_table = False
                continue
            m = ROW.match(line)
            if m:
                rows[m.group(1)] = (m.group(2), m.group(3))
    return rows


def bullets(body, label):
    names, active = [], False
    for line in body:
        if line.strip() == f"{label}:":
            active = True
            continue
        if active:
            m = re.match(r"^- `([^`]+)`", line)
            if m:
                names.append(m.group(1))
            elif line.strip() == "":
                active = False
    return names


doc = read_doc()
workflows = sorted(os.path.basename(p) for p in glob.glob(".github/workflows/reusable-*.yml"))
check(len(workflows) > 0, "no reusable-*.yml workflows found (harness broken)")

documented = set()
for heading, body in sections(doc):
    key = next((k for k in SECTION_MAP if heading.startswith(k)), None)
    check(key is not None,
          f"section '### {heading}' has no entry in SECTION_MAP; map it to its workflow file")
    if key is None:
        continue
    wf = SECTION_MAP[key]
    documented.add(wf)
    inputs, secrets, outputs = contract(wf)
    rows = input_rows(body)
    check(len(rows) > 0, f"{wf}: no input rows parsed from '### {heading}' (harness broken?)")

    for name, spec in inputs.items():
        row = rows.get(name)
        check(row is not None, f"{wf}: input `{name}` has no row in '### {heading}'")
        if row is None:
            continue
        doc_type, doc_default = row
        check(doc_type == spec.get("type"),
              f"{wf}: input `{name}` type documented `{doc_type}`, declared `{spec.get('type')}`")
        declared = norm(spec.get("default"))
        shown = norm(doc_default)
        if shown.strip("*_ ").lower() == "see workflow":
            check(len(declared) > LONG_DEFAULT,
                  f"{wf}: input `{name}` default documented as 'see workflow' but the "
                  f"declared default is short enough to show: `{declared}`")
        elif spec.get("required") and "default" not in spec:
            check(shown in ("", "—", "required"),
                  f"{wf}: required input `{name}` documents a default `{shown}`")
        else:
            check(shown == declared,
                  f"{wf}: input `{name}` default documented `{shown}`, declared `{declared}`")
    for name in rows:
        check(name in inputs, f"{wf}: row `{name}` in '### {heading}' is not a declared input")

    doc_secrets = bullets(body, "Secrets")
    for name in secrets:
        check(name in doc_secrets, f"{wf}: secret `{name}` has no bullet under 'Secrets:'")
    for name in doc_secrets:
        check(name in secrets, f"{wf}: 'Secrets:' bullet `{name}` is not a declared secret")

    doc_outputs = bullets(body, "Outputs")
    for name in outputs:
        check(name in doc_outputs, f"{wf}: output `{name}` has no bullet under 'Outputs:'")
    for name in doc_outputs:
        check(name in outputs, f"{wf}: 'Outputs:' bullet `{name}` is not a declared output")

for wf in SECTION_MAP.values():
    check(wf in documented, f"SECTION_MAP names {wf} but the rule has no section for it")


# Callers shown to readers: YAML examples in the rule and workflow templates.
USES = re.compile(r"ForumViriumHelsinki/\.github/\.github/workflows/(reusable-[\w-]+\.yml)@")


def walk_callers(node, where):
    if isinstance(node, dict):
        m = USES.search(str(node.get("uses", "")))
        if m:
            yield m.group(1), node, where
        for v in node.values():
            yield from walk_callers(v, where)
    elif isinstance(node, list):
        for v in node:
            yield from walk_callers(v, where)


callers = []
for n, block in enumerate(re.findall(r"```ya?ml\n(.*?)```", doc, flags=re.S), 1):
    if not USES.search(block):
        continue
    parsed = json.loads(subprocess.run(["yq", "-o=json", "."], input=block, check=True,
                                       capture_output=True, text=True).stdout)
    callers += walk_callers(parsed, f"rule YAML example #{n}")
for path in sorted(glob.glob("workflow-templates/*.yml")):
    callers += walk_callers(yq_json(".", path), path)

check(len(callers) > 0, "no reusable-workflow callers found in examples/templates (harness broken)")
for wf, node, where in callers:
    check(wf in workflows, f"{where}: calls {wf}, which does not exist")
    if wf not in workflows:
        continue
    inputs, secrets, _ = contract(wf)
    for key in (node.get("with") or {}):
        check(key in inputs, f"{where}: passes `with: {key}` to {wf}, which declares no such input")
    sec = node.get("secrets")
    if isinstance(sec, dict):
        for key in sec:
            check(key in secrets, f"{where}: passes secret `{key}` to {wf}, which declares no such secret")

undocumented = [wf for wf in workflows if wf not in documented]
if undocumented:
    print(f"NOTICE: {len(undocumented)} reusable workflow(s) have no inputs section in "
          f"the CI/CD rule (not enforced): " + ", ".join(undocumented))

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}")
    print(f"FAIL: {NAME} ({len(failures)} of {assertions} assertion(s) failed)")
    sys.exit(1)
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY
