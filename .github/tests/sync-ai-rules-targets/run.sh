#!/usr/bin/env bash
# Pins the two silent-zero-files traps in every rulesync invocation shipped by
# this repo's workflows and starter templates:
#
#   generate  must pass --targets and --features equal to this repo's
#             rulesync.jsonc. A consuming repo has no rulesync.jsonc (fetch
#             pulls only .rulesync/), and a bare `generate` then resolves to the
#             agentsmd target alone and writes zero files at exit 0.
#   fetch     must pass --path .rulesync. rulesync >= 9 resolves features
#             against the source repo root, so without it the fetch 404s on
#             rules/ and returns zero files at exit 0.
#
# The commands are extracted from the shipped workflow text, not retyped here.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

python3 - <<'PY'
import glob
import json
import re
import shlex
import sys

NAME = "sync-ai-rules-targets"


def strip_jsonc(text):
    """Drop // and /* */ comments outside strings, then trailing commas."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
        elif c == '"':
            in_str = True
            out.append(c)
            i += 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            if end < 0:
                sys.exit(f"FAIL: {NAME}: unterminated /* comment in rulesync.jsonc")
            i = end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


with open("rulesync.jsonc", encoding="utf-8") as fh:
    config = json.loads(strip_jsonc(fh.read()))
want_targets = config.get("targets")
want_features = config.get("features")
if not isinstance(want_targets, list) or not want_targets:
    sys.exit(f"FAIL: {NAME}: rulesync.jsonc has no array 'targets' (the object form is not handled by this test)")
if not isinstance(want_features, list) or not want_features:
    sys.exit(f"FAIL: {NAME}: rulesync.jsonc has no array 'features'")

# Only what a consuming repo runs: the reusable workflows and the starter
# templates. Workflows local to this repo (lint.yml's `generate --check`) run
# next to this repo's own rulesync.jsonc, so the no-config trap cannot reach them.
files = sorted(
    glob.glob(".github/workflows/reusable-*.yml")
    + glob.glob(".github/workflows/reusable-*.yaml")
    + glob.glob("workflow-templates/*.yml")
    + glob.glob("workflow-templates/*.yaml")
)
if not files:
    sys.exit(f"FAIL: {NAME}: found no workflow files to scan")


def logical_lines(path):
    """Yield (lineno, text): backslash continuations joined, YAML comment lines skipped."""
    buf, start = "", None
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not buf and line.lstrip().startswith("#"):
                continue
            if start is None:
                start = no
            if line.rstrip().endswith("\\"):
                buf += line.rstrip()[:-1] + " "
                continue
            yield start, buf + line
            buf, start = "", None
    if buf:
        yield start, buf


# Matches `rulesync`, `rulesync@latest`, `rulesync@1.2.3`, `npx -y rulesync generate`, ...
INVOCATION = re.compile(r"(?:^|[\s;&|(`'\"])rulesync(?:@\S+)?\s+(fetch|generate)\b([^;&|\n]*)")


def flag_value(tokens, long, short):
    for k, tok in enumerate(tokens):
        if tok in (long, short) and k + 1 < len(tokens):
            return tokens[k + 1]
        if tok.startswith(long + "="):
            return tok.split("=", 1)[1]
    return None


failures, assertions, counts = [], 0, {"fetch": 0, "generate": 0}
for path in files:
    for lineno, text in logical_lines(path):
        for match in INVOCATION.finditer(text):
            sub, rest = match.group(1), match.group(2)
            counts[sub] += 1
            where = f"{path}:{lineno}"
            try:
                tokens = shlex.split(rest, comments=True)
            except ValueError as err:
                failures.append(f"{where}: cannot tokenize rulesync {sub} arguments ({err})")
                continue
            if sub == "generate":
                got_t = flag_value(tokens, "--targets", "-t")
                got_f = flag_value(tokens, "--features", "-f")
                assertions += 2
                if got_t is None:
                    failures.append(
                        f"{where}: `rulesync generate` has no --targets; a caller without rulesync.jsonc "
                        f"generates only agentsmd (zero files). Expected --targets {','.join(want_targets)}"
                    )
                elif got_t.split(",") != want_targets:
                    failures.append(f"{where}: --targets {got_t} != rulesync.jsonc targets {','.join(want_targets)}")
                if got_f is None:
                    failures.append(
                        f"{where}: `rulesync generate` has no --features. Expected --features {','.join(want_features)}"
                    )
                elif got_f.split(",") != want_features:
                    failures.append(f"{where}: --features {got_f} != rulesync.jsonc features {','.join(want_features)}")
            else:
                got_p = flag_value(tokens, "--path", "--path")
                assertions += 1
                if got_p is None:
                    failures.append(
                        f"{where}: `rulesync fetch` has no --path .rulesync; the fetch 404s on rules/ and returns zero files"
                    )
                elif got_p.rstrip("/") != ".rulesync":
                    failures.append(f"{where}: `rulesync fetch` --path {got_p} != .rulesync")

# Non-vacuous: the extractor must find the shipped sync workflow's commands.
assertions += 1
if counts["generate"] == 0 or counts["fetch"] == 0:
    failures.append(
        f"extractor found {counts['fetch']} fetch and {counts['generate']} generate invocation(s) across "
        f"{len(files)} file(s); expected at least one of each (reusable-sync-ai-rules.yml)"
    )

if failures:
    for f in failures:
        print(f"FAIL: {NAME}: {f}", file=sys.stderr)
    sys.exit(1)
print(f"scanned {len(files)} workflow file(s): {counts['fetch']} fetch, {counts['generate']} generate invocation(s)")
print(f"PASS: {NAME} ({assertions} assertion(s))")
PY
