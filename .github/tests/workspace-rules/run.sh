#!/usr/bin/env bash
# scripts/workspace-rules.sh copies the generated Claude rules into the parent
# of a clone of this repo, for people who start Claude Code from a directory
# holding several FVH repos.
#
# Runs the shipped script (copied, not retyped) from a scratch clone layout:
#   ws/.github/{scripts/workspace-rules.sh, .claude/rules/*.md}
#   ws/.claude/rules/own.md   <- a rule the workspace owns
#
# Assertions:
#   1. The justfile's workspace-rules recipe calls the script.
#   2. First run: every generated rule lands in ws/.claude/rules byte-identical,
#      from .claude/rules (paths:), not .rulesync/rules (globs:).
#   3. The manifest lists exactly the copied names.
#   4. A rule deleted from the source is removed on the next run; the
#      workspace's own rule survives both runs.
#   5. A manifest line naming a path outside the rules dir is not followed.
#   6. ws/CLAUDE.md gains exactly `@.github/workspace/CLAUDE.md`, which resolves
#      (relative to the importing file) to the shipped guide.
#   7. An existing CLAUDE.md, last line without a newline, keeps its content and
#      gains the import once across two runs.
#   8. With DEST elsewhere, the import is the guide's absolute path.
#   9. A clone with no generated rules fails non-zero.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

assertions=0
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
ok() { assertions=$((assertions + 1)); }

# 1. Recipe wiring
recipe="$(awk '/^workspace-rules/{f=1; print; next} f && /^[^ ]/{f=0} f' justfile)"
[ -n "$recipe" ] || fail "no workspace-rules recipe in justfile"
grep -F 'scripts/workspace-rules.sh' >/dev/null <<<"$recipe" || fail "workspace-rules recipe does not call scripts/workspace-rules.sh"
ok

shopt -s nullglob
generated=(.claude/rules/*.md)
shopt -u nullglob
[ "${#generated[@]}" -gt 0 ] || fail "no generated rules under .claude/rules to copy"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
ws="$scratch/ws"
mkdir -p "$ws/.github/scripts" "$ws/.github/.claude/rules" "$ws/.github/.rulesync/rules" "$ws/.claude/rules"
cp scripts/workspace-rules.sh "$ws/.github/scripts/"
cp "${generated[@]}" "$ws/.github/.claude/rules/"
# The sources too, so a script reading .rulesync/rules fails assertion 2, not "no rules found".
cp .rulesync/rules/*.md "$ws/.github/.rulesync/rules/"
mkdir -p "$ws/.github/workspace"
cp workspace/CLAUDE.md "$ws/.github/workspace/"
echo "# workspace-owned" >"$ws/.claude/rules/own.md"
dst="$ws/.claude/rules"

# 2. First run
bash "$ws/.github/scripts/workspace-rules.sh" >/dev/null
for f in "${generated[@]}"; do
  name="$(basename "$f")"
  cmp -s "$f" "$dst/$name" || fail "$name missing or differs after first run"
  head -5 "$dst/$name" | grep -E '^globs:' >/dev/null && fail "$name carries globs: (copied from .rulesync/rules?)"
done
ok

# 3. Manifest
expected="$(for f in "${generated[@]}"; do basename "$f"; done | LC_ALL=C sort)"
actual="$(LC_ALL=C sort "$dst/.fvh-rules-manifest")"
[ "$expected" = "$actual" ] || fail "manifest does not list exactly the copied rules"
ok

# 4. Orphan removal, workspace rule preserved
victim="$(basename "${generated[0]}")"
rm "$ws/.github/.claude/rules/$victim"
bash "$ws/.github/scripts/workspace-rules.sh" >/dev/null
[ ! -e "$dst/$victim" ] || fail "$victim deleted from source but still in workspace"
[ -f "$dst/own.md" ] || fail "workspace-owned own.md was removed"
grep -Fx "$victim" "$dst/.fvh-rules-manifest" >/dev/null && fail "$victim still listed in manifest"
ok

# 5. Hostile manifest line
echo "outside" >"$ws/.claude/outside.md"
printf '../outside.md\n' >>"$dst/.fvh-rules-manifest"
bash "$ws/.github/scripts/workspace-rules.sh" >/dev/null
[ -f "$ws/.claude/outside.md" ] || fail "manifest line ../outside.md deleted a file outside the rules dir"
ok

# 6. Import line in a fresh workspace
[ "$(cat "$ws/CLAUDE.md")" = "@.github/workspace/CLAUDE.md" ] || fail "ws/CLAUDE.md is not exactly the import line: $(cat "$ws/CLAUDE.md")"
cmp -s "$ws/.github/workspace/CLAUDE.md" "$ws/$(sed 's/^@//' "$ws/CLAUDE.md")" || fail "import does not resolve to the shipped guide"
ok

# 7. Existing CLAUDE.md preserved, import added once
ws2="$scratch/ws2"
mkdir -p "$ws2"
cp -R "$ws/.github" "$ws2/.github"
printf '# mine' >"$ws2/CLAUDE.md"
bash "$ws2/.github/scripts/workspace-rules.sh" >/dev/null
bash "$ws2/.github/scripts/workspace-rules.sh" >/dev/null
[ "$(cat "$ws2/CLAUDE.md")" = "$(printf '# mine\n@.github/workspace/CLAUDE.md')" ] || fail "existing CLAUDE.md not preserved with one import appended: $(cat "$ws2/CLAUDE.md")"
ok

# 8. DEST elsewhere gets an absolute import
other="$scratch/other"
mkdir -p "$other"
bash "$ws/.github/scripts/workspace-rules.sh" "$other" >/dev/null
guide_abs="$(cd "$ws/.github/workspace" && pwd)/CLAUDE.md"
[ "$(cat "$other/CLAUDE.md")" = "@$guide_abs" ] || fail "DEST elsewhere: expected @$guide_abs, got $(cat "$other/CLAUDE.md")"
ok

# 9. Empty source fails
rm "$ws/.github/.claude/rules/"*.md
if bash "$ws/.github/scripts/workspace-rules.sh" >/dev/null 2>&1; then
  fail "script exited 0 with no generated rules to copy"
fi
ok

echo "PASS: workspace-rules ($assertions assertion(s))"
