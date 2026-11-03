#!/usr/bin/env bash
# Copy this repo's generated Claude Code rules into a workspace directory, for
# people who keep FVH repos side by side under one parent and start Claude Code
# from that parent:
#
#   parent/.github/      <- a clone of this repo
#   parent/.claude/rules <- written here
#   parent/CLAUDE.md     <- gains one import line
#
# Usage: bash scripts/workspace-rules.sh [DEST]   # DEST defaults to the
#                                                 # directory this clone is in
#
# Copies .claude/rules/*.md (rulesync's claudecode output, which carries the
# `paths:` frontmatter Claude Code reads), never .rulesync/rules/ (whose
# `globs:` Claude Code ignores, so every rule would load at launch). Copies
# rather than symlinks: a symlink pointing outside the working directory is an
# external import, and path-scoped rules do not load through one.
#
# The names copied are recorded in DEST/.claude/rules/.fvh-rules-manifest. On
# the next run the files listed there are removed first, so a rule deleted or
# renamed here disappears from the workspace too, while rules the workspace
# owns are left alone.
#
# It also appends `@.github/workspace/CLAUDE.md` (the developer guide in this
# repo) to DEST/CLAUDE.md, creating the file if needed and adding the line
# only once.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
src="$repo/.claude/rules"
dest="${1:-$repo/..}"
dst="$dest/.claude/rules"
manifest="$dst/.fvh-rules-manifest"

shopt -s nullglob
rules=("$src"/*.md)
shopt -u nullglob
if [ "${#rules[@]}" -eq 0 ]; then
  echo "ERROR: no rules found at $src" >&2
  exit 1
fi

mkdir -p "$dst"
removed=0
if [ -f "$manifest" ]; then
  while IFS= read -r name; do
    # Manifest lines are bare file names; refuse anything that could escape $dst.
    case "$name" in
      "" | */* | .*) continue ;;
    esac
    if [ -f "$dst/$name" ]; then
      rm -f "$dst/$name"
      removed=$((removed + 1))
    fi
  done <"$manifest"
fi

: >"$manifest"
for f in "${rules[@]}"; do
  cp "$f" "$dst/"
  basename "$f" >>"$manifest"
done

echo "Copied ${#rules[@]} rules to $(cd "$dst" && pwd) (replaced $removed from the previous copy)"

# Import workspace/CLAUDE.md from DEST/CLAUDE.md instead of copying it, so a
# `git pull` of this clone updates it and a workspace's own CLAUDE.md is never
# overwritten. Imports resolve relative to the importing file; use a relative
# path when this clone sits directly in DEST, an absolute one otherwise.
guide="$repo/workspace/CLAUDE.md"
[ -f "$guide" ] || {
  echo "ERROR: no workspace guide at $guide" >&2
  exit 1
}
if [ "$(cd "$dest" && pwd -P)" = "$(cd "$repo/.." && pwd -P)" ]; then
  import="@$(basename "$repo")/workspace/CLAUDE.md"
else
  import="@$guide"
fi
claude_md="$dest/CLAUDE.md"
if [ -f "$claude_md" ] && grep -Fx -- "$import" "$claude_md" >/dev/null; then
  echo "$(cd "$dest" && pwd)/CLAUDE.md already imports $import"
else
  # Keep an existing last line that lacks a newline on its own line.
  if [ -s "$claude_md" ] && [ -n "$(tail -c 1 "$claude_md")" ]; then
    echo >>"$claude_md"
  fi
  echo "$import" >>"$claude_md"
  echo "Added $import to $(cd "$dest" && pwd)/CLAUDE.md"
fi
