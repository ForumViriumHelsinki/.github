#!/usr/bin/env bash
# Regression test for #113: a generated Claude Code permission deny must not
# cover a git-tracked source-of-truth path.
#
# rulesync's `ignore` feature turns every line of .rulesync/.aiignore into a
# `Read(<pattern>)` deny in .claude/settings.json (and a line in .cursorignore
# and .geminiignore). A Claude Code Read deny also blocks Edit, Write and
# path-naming Bash commands, so an .aiignore line that covers the rule sources
# makes the documented source of truth uneditable from a Claude session.
#
# Assertions:
#   1. .claude/settings.json permissions.deny has no entry covering .rulesync/
#      or rulesync.jsonc.
#   2. .rulesync/.aiignore does not list them.
#   3. .cursorignore and .geminiignore equal .aiignore, and the Read(...) deny
#      set equals the .aiignore pattern set (generated copies in sync).
#   4. Class-wide: no Read/Edit/Write deny in any .claude/settings*.json in the
#      repo covers a git-tracked file, and none covers a path CLAUDE.md
#      documents as the source of truth / canonical source.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# .aiignore content: a direct read works in CI; inside a Claude Code session
# whose settings still deny the path, fall back to the committed copy.
if aiignore="$(cat .rulesync/.aiignore 2>/dev/null)"; then
  aiignore_src="working tree"
else
  aiignore="$(git show HEAD:.rulesync/.aiignore)"
  aiignore_src="HEAD"
fi

tracked="$(git ls-files)"
settings_files="$(find . -path ./.git -prune -o -path ./node_modules -prune -o -path ./.claude/worktrees -prune -o -type f -path '*/.claude/settings*.json' -print | sed 's|^\./||' | sort)"

AIIGNORE="$aiignore" AIIGNORE_SRC="$aiignore_src" TRACKED="$tracked" SETTINGS_FILES="$settings_files" python3 - <<'PY'
import fnmatch
import json
import os
import re
import sys

failures = []
assertions = 0


def check(cond, msg):
    global assertions
    assertions += 1
    if not cond:
        failures.append(msg)


def covers(pattern, path):
    """gitignore-style: does `pattern` cover repo-relative `path`?"""
    p = pattern
    if p.startswith("./"):
        p = p[2:]
    anchored = p.startswith("/")
    p = p.lstrip("/")
    if not p:
        return False
    parts = path.split("/")
    if p.endswith("/"):
        d = p[:-1]
        if "/" in d or anchored:
            return path.startswith(d + "/")
        # unanchored dir name: any leading directory component
        return any(fnmatch.fnmatchcase(c, d) for c in parts[:-1])
    if "/" in p or anchored:
        return fnmatch.fnmatchcase(path, p) or path.startswith(p + "/")
    return any(fnmatch.fnmatchcase(c, p) for c in parts)


def patterns(text):
    return [l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("#")]


def deny_paths(settings_path):
    """(entry, pattern) for every repo-relative Read/Edit/Write deny."""
    with open(settings_path) as f:
        data = json.load(f)
    out = []
    for entry in data.get("permissions", {}).get("deny", []) or []:
        m = re.fullmatch(r"(Read|Edit|Write)\((.*)\)", entry)
        if not m:
            continue
        pat = m.group(2)
        if pat.startswith(("//", "~")):
            continue  # absolute / home paths are outside the repo
        out.append((entry, pat))
    return out


# Matcher self-test, so a broken matcher cannot make assertion 4 vacuous.
check(covers(".rulesync/", ".rulesync/rules/ci-cd-workflows.md"), "matcher self-test: dir pattern")
check(covers("rulesync.jsonc", "rulesync.jsonc"), "matcher self-test: file pattern")
check(not covers("node_modules/", "README.md"), "matcher self-test: non-match")

guarded = [".rulesync/rules/ci-cd-workflows.md", ".rulesync/.aiignore", "rulesync.jsonc"]

# 1. The shipped settings.json deny list.
root_denies = deny_paths(".claude/settings.json")
check(root_denies, ".claude/settings.json has no Read deny at all; the rulesync ignore feature is expected to emit some")
for entry, pat in root_denies:
    for g in guarded:
        check(not covers(pat, g), f".claude/settings.json deny {entry} covers {g}")

# 2. The .aiignore source.
aiignore = os.environ["AIIGNORE"]
src_patterns = patterns(aiignore)
for pat in src_patterns:
    for g in guarded:
        check(not covers(pat, g), f".rulesync/.aiignore ({os.environ['AIIGNORE_SRC']}) line {pat!r} covers {g}")

# 3. Generated copies in sync with the source.
for gen in (".cursorignore", ".geminiignore"):
    with open(gen) as f:
        check(f.read().strip() == aiignore.strip(), f"{gen} differs from .rulesync/.aiignore; run npx rulesync@latest generate")
root_read = sorted(p for e, p in root_denies if e.startswith("Read("))
check(root_read == sorted(src_patterns),
      f".claude/settings.json Read denies {root_read} != .aiignore patterns {sorted(src_patterns)}; run npx rulesync@latest generate")

# 4. Class-wide scan.
tracked = [t for t in os.environ["TRACKED"].splitlines() if t]
check(tracked, "git ls-files returned nothing")
with open("CLAUDE.md") as f:
    claude_md = f.read()
sot_globs = set()
for line in claude_md.splitlines():
    if re.search(r"source of truth|canonical source", line, re.I):
        sot_globs.update(re.findall(r"`([^`\s]+/[^`\s]*)`", line))
sot_files = sorted({t for t in tracked for g in sot_globs if covers(g, t)})
check(sot_files, f"no tracked file matched the CLAUDE.md source-of-truth paths {sorted(sot_globs)}")

settings_files = [s for s in os.environ["SETTINGS_FILES"].splitlines() if s]
check(".claude/settings.json" in settings_files, "settings scan did not find .claude/settings.json")
for sf in settings_files:
    base = os.path.dirname(os.path.dirname(sf))  # dir that holds .claude/
    prefix = base + "/" if base else ""
    for entry, pat in deny_paths(sf):
        scoped = [t[len(prefix):] for t in tracked if t.startswith(prefix)]
        hit_sot = [t for t in sot_files if t.startswith(prefix) and covers(pat, t[len(prefix):])]
        check(not hit_sot, f"{sf} deny {entry} covers source-of-truth file(s): {', '.join(hit_sot[:5])}")
        hit_tracked = [t for t in scoped if covers(pat, t)]
        check(not hit_tracked, f"{sf} deny {entry} covers tracked file(s): {', '.join(hit_tracked[:5])}")

if failures:
    for msg in failures:
        print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: rulesync-ignore ({assertions} assertion(s))")
PY
