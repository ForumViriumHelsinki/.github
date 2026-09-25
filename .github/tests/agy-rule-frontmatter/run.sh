#!/usr/bin/env bash
# Every generated Antigravity rule carries `trigger:` frontmatter.
#
# Antigravity (agy 1.2.10) never loads a `.agents/rules/*.md` file without a
# `trigger:` line, whether or not a matching file is open (verified with
# sentinel rules, 2026-09). rulesync's old `antigravity-cli` target wrote the
# rules with no frontmatter at all; `antigravity-ide` writes `trigger: glob` +
# `globs:` or `trigger: always_on`. A rule source whose own `targets:` list
# still names another Antigravity target gets no `.agents/rules` copy, and
# `generate --check` reports that as up to date.
#
# Assertions:
#   1. No rule source names the `antigravity-cli` target.
#   2. The set of rule sources targeting `antigravity-ide` equals the set of
#      files in .agents/rules/ (none missing, none stale).
#   3. Every .agents/rules/*.md opens with a frontmatter block whose `trigger:`
#      is always_on, glob, manual or model_decision; a glob trigger has a
#      non-empty `globs:`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import glob, os, re, sys

NAME = "agy-rule-frontmatter"
failures, assertions = [], 0


def check(ok, msg):
    global assertions
    assertions += 1
    if not ok:
        failures.append(msg)


def frontmatter(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    return m.group(1) if m else None


sources = sorted(glob.glob(".rulesync/rules/*.md"))
generated = sorted(glob.glob(".agents/rules/*.md"))
check(sources, "no .rulesync/rules/*.md sources found (harness broken)")
check(generated, "no .agents/rules/*.md files found")

targeted = set()
for src in sources:
    fm = frontmatter(src) or ""
    m = re.search(r"^targets:\s*(\[.*\])\s*$", fm, re.M)
    names = re.findall(r'"([^"]+)"', m.group(1)) if m else []
    check("antigravity-cli" not in names,
          f"{src}: targets lists antigravity-cli; use antigravity-ide (the -cli target writes no trigger frontmatter)")
    if "antigravity-ide" in names or "*" in names:
        targeted.add(os.path.basename(src))

check(targeted == {os.path.basename(g) for g in generated},
      f".agents/rules does not match the rule sources targeting antigravity-ide: "
      f"missing {sorted(targeted - {os.path.basename(g) for g in generated})}, "
      f"stale {sorted({os.path.basename(g) for g in generated} - targeted)}; run npx rulesync@latest generate")

for path in generated:
    fm = frontmatter(path)
    check(fm is not None, f"{path}: no frontmatter block; Antigravity will not load it")
    if fm is None:
        continue
    t = re.search(r"^trigger:\s*(\S+)\s*$", fm, re.M)
    check(t is not None, f"{path}: frontmatter has no trigger:")
    if t is None:
        continue
    trigger = t.group(1)
    check(trigger in {"always_on", "glob", "manual", "model_decision"},
          f"{path}: unknown trigger {trigger!r}")
    if trigger == "glob":
        g = re.search(r"^globs:\s*(\S.*)$", fm, re.M)
        check(g is not None and g.group(1).strip("'\" ") != "",
              f"{path}: trigger: glob without globs:")

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}")
    sys.exit(1)
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY
