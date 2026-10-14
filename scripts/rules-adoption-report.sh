#!/usr/bin/env bash
# Report how far the org AI rules in .claude/rules/ have reached the org's repos
# (issue #111). Reads only: one `GET /orgs/<org>/repos` listing, then one
# `GET /repos/<org>/<repo>/contents/.claude/rules` per non-archived repo.
#
# The reference is this repo's generated .claude/rules/, not .rulesync/rules/:
# a consumer's copy is `rulesync generate` output, so a byte match against the
# generated file is a git blob SHA match, and the listing alone carries the SHA.
#
# Every repo lands in exactly one bucket:
#   drifted   at least one file named like an org rule, with different content
#   matching  org-named files present, all byte-identical (missing ones counted)
#   absent    no org-named file (with or without its own local .claude/rules/)
# Drifted and absent are kept apart: an absent repo never opted in, a drifted
# one holds an org rule name with other content (stale copy or local rule).
#
# Markdown goes to stdout. Exits 1 after printing when any repo could not be
# read, when the token sees no private repo (a token without private access
# returns only public repos from the listing, and every private repo would
# silently vanish from the report), or when the source repo itself does not
# match: it is listed like any other repo, so it is the comparison's control.
#
# Usage: GH_TOKEN=... scripts/rules-adoption-report.sh [org]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

org="${1:-ForumViriumHelsinki}"
source_repo="${SOURCE_REPO:-.github}"
rules_dir=".claude/rules"

shopt -s nullglob
declare -A expected=()
for f in "$rules_dir"/*.md; do
  expected["${f##*/}"]="$(git hash-object "$f")"
done
shopt -u nullglob
total="${#expected[@]}"
[ "$total" -gt 0 ] || { echo "::error::no $rules_dir/*.md in this checkout to compare against" >&2; exit 1; }

repos="$(gh api --paginate "orgs/$org/repos?type=all&per_page=100" \
  | jq -r '.[] | select(.archived | not) | [.name, .visibility] | @tsv' | sort -f)"
[ -n "$repos" ] || { echo "::error::listing orgs/$org/repos returned no non-archived repo" >&2; exit 1; }

scanned=0 private=0 errors=0 source_ok=false
n_drifted=0 n_matching=0 n_absent_local=0 n_absent_none=0
drifted_rows="" matching_rows="" absent_local="" error_rows=""
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

while IFS=$'\t' read -r repo visibility; do
  scanned=$((scanned + 1))
  [ "$visibility" = private ] && private=$((private + 1))
  if ! listing="$(gh api "repos/$org/$repo/contents/$rules_dir" 2>"$err")"; then
    if grep -F 'HTTP 404' "$err" >/dev/null; then
      n_absent_none=$((n_absent_none + 1))
    else
      errors=$((errors + 1))
      msg="$(cat "$err")"
      msg="${msg//$'\n'/ }"
      error_rows+="| \`$repo\` | ${msg//|//} |"$'\n'
    fi
    continue
  fi
  # A file (not a directory) at .claude/rules returns an object, not an array.
  files="$(jq -r 'if type == "array" then .[] | select(.type == "file") | [.name, .sha] | @tsv else empty end' <<<"$listing")"
  match=0 drift=0 local_only=0 drift_names=""
  while IFS=$'\t' read -r name sha; do
    [ -n "$name" ] || continue
    if [ -z "${expected[$name]+set}" ]; then
      local_only=$((local_only + 1))
    elif [ "${expected[$name]}" = "$sha" ]; then
      match=$((match + 1))
    else
      drift=$((drift + 1))
      drift_names+="${drift_names:+, }\`$name\`"
    fi
  done <<<"$files"
  missing=$((total - match - drift))
  row="| \`$repo\` | $match | $drift | $missing | $local_only | ${drift_names:--} |"$'\n'
  if [ "$drift" -gt 0 ]; then
    n_drifted=$((n_drifted + 1))
    drifted_rows+="$row"
  elif [ "$match" -gt 0 ]; then
    n_matching=$((n_matching + 1))
    matching_rows+="$row"
    if [ "$repo" = "$source_repo" ] && [ "$missing" -eq 0 ]; then source_ok=true; fi
  else
    n_absent_local=$((n_absent_local + 1))
    absent_local+="${absent_local:+, }\`$repo\` ($local_only local)"
  fi
done <<<"$repos"

header='| Repo | Matching | Drifted | Missing | Local-only | Drifted files |
|---|---:|---:|---:|---:|---|'

cat <<EOF
# AI rules adoption report

Reference: \`$rules_dir/\` in \`$org/$source_repo\` ($total rules). Scanned $scanned non-archived repos ($private private).

| Bucket | Repos |
|---|---:|
| Drifted (org rule name present, content differs) | $n_drifted |
| Matching (org rules present, all byte-identical) | $n_matching |
| Absent, with a local \`$rules_dir/\` | $n_absent_local |
| Absent, no \`$rules_dir/\` | $n_absent_none |
| Could not be read | $errors |

**Missing** counts org rules the repo does not carry at all. **Local-only** counts files in the repo's \`$rules_dir/\` that are not org rules.

## Drifted

EOF
if [ -n "$drifted_rows" ]; then printf '%s\n%s\n' "$header" "$drifted_rows"; else printf 'None.\n\n'; fi
printf '## Matching\n\n'
if [ -n "$matching_rows" ]; then printf '%s\n%s\n' "$header" "$matching_rows"; else printf 'None.\n\n'; fi
printf '## Absent, with a local `%s/`\n\n%s\n\n' "$rules_dir" "${absent_local:-None.}"
if [ -n "$error_rows" ]; then
  printf '## Could not be read\n\n| Repo | Error |\n|---|---|\n%s\n' "$error_rows"
fi

status=0
if [ "$private" -eq 0 ]; then
  echo "::error::the token sees no private repo in $org; private repos are missing from this report" >&2
  status=1
fi
if [ "$errors" -gt 0 ]; then
  echo "::error::$errors repo(s) could not be read; see the 'Could not be read' table" >&2
  status=1
fi
if [ "$source_ok" != true ]; then
  echo "::error::$org/$source_repo does not match its own $rules_dir/ (default branch differs from this checkout, or the comparison is broken)" >&2
  status=1
fi
exit "$status"
