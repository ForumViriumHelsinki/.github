#!/usr/bin/env bash
# Runs the shipped scripts/rules-adoption-report.sh against a stubbed `gh` and
# checks the buckets and the three fail-closed exits (issue #111):
#
#   1. drifted, matching and absent stay separate buckets; archived repos are
#      never requested; the source repo is listed and matches itself.
#   2. a non-404 read error still prints the report, lists the repo under
#      "Could not be read", and exits 1.
#   3. a listing with no private repo (a token without private access) exits 1.
#   4. the source repo not matching its own .claude/rules/ exits 1.
#
# Fixture SHAs for org rules come from `git hash-object` on this checkout's
# .claude/rules/, the same values the script compares against.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NAME="rules-adoption-report"
SCRIPT="scripts/rules-adoption-report.sh"
assertions=0
fail() { echo "FAIL: $NAME: $*" >&2; exit 1; }
ok() { assertions=$((assertions + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Sentinel: every call is logged; the real gh never writes this file.
echo "STUB-GH $*" >>"$FIXTURES/calls.log"
[ "$1" = api ] || { echo "stub: unexpected gh $*" >&2; exit 99; }
shift
[ "${1:-}" = --paginate ] && shift
case "$1" in
  orgs/*/repos*) cat "$FIXTURES/repos.json" ;;
  repos/*/contents/.claude/rules)
    repo="${1#repos/*/}"; repo="${repo%%/contents/*}"
    if [ -f "$FIXTURES/$repo.404" ]; then
      echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1
    elif [ -f "$FIXTURES/$repo.500" ]; then
      echo 'gh: Server Error (HTTP 500)' >&2; exit 1
    elif [ -f "$FIXTURES/$repo.json" ]; then
      cat "$FIXTURES/$repo.json"
    else
      echo "stub: no fixture for $repo" >&2; exit 99
    fi ;;
  *) echo "stub: unexpected path $1" >&2; exit 99 ;;
esac
STUB
chmod +x "$work/bin/gh"

shopt -s nullglob
rules=(.claude/rules/*.md)
shopt -u nullglob
[ "${#rules[@]}" -ge 2 ] || fail "need at least two .claude/rules/*.md to build fixtures, found ${#rules[@]}"
ok
r1="${rules[0]##*/}" r2="${rules[1]##*/}"
sha1="$(git hash-object "${rules[0]}")" sha2="$(git hash-object "${rules[1]}")"

# listing <name>:<sha> ... -> a contents API directory listing
listing() {
  printf '%s\n' "$@" | jq -R 'split(":") | {name: .[0], sha: .[1], type: "file"}' | jq -s .
}

source_listing() {
  local f entries=()
  for f in "${rules[@]}"; do entries+=("${f##*/}:$(git hash-object "$f")"); done
  listing "${entries[@]}"
}

# run <fixture-dir> -> sets out, errout, status
run() {
  : >"$1/calls.log"
  status=0
  out="$(FIXTURES="$1" PATH="$work/bin:$PATH" bash "$SCRIPT" TestOrg 2>"$1/stderr")" || status=$?
  errout="$(cat "$1/stderr")"
  grep -F 'STUB-GH' "$1/calls.log" >/dev/null || fail "stub gh was never called (sentinel missing): the real gh may have run"
  ok
}

has() { grep -F -- "$1" <<<"$2" >/dev/null; }

# ------------------------------------------------------------- 1. buckets
f="$work/ok"; mkdir -p "$f"
cat >"$f/repos.json" <<'EOF'
[{"name":".github","visibility":"public","archived":false},
 {"name":"drift-repo","visibility":"private","archived":false},
 {"name":"match-repo","visibility":"private","archived":false}]
[{"name":"local-repo","visibility":"private","archived":false},
 {"name":"none-repo","visibility":"public","archived":false},
 {"name":"old-repo","visibility":"private","archived":true}]
EOF
source_listing >"$f/.github.json"
listing "$r1:0000000000000000000000000000000000000000" "$r2:$sha2" "local-only.md:abc" >"$f/drift-repo.json"
listing "$r1:$sha1" "$r2:$sha2" >"$f/match-repo.json"
listing "local-only.md:abc" "another.md:def" >"$f/local-repo.json"
: >"$f/none-repo.404"
run "$f"
[ "$status" -eq 0 ] || fail "happy path exited $status: $errout"
ok
for want in \
  "Scanned 5 non-archived repos (3 private)" \
  "| Drifted (org rule name present, content differs) | 1 |" \
  "| Matching (org rules present, all byte-identical) | 2 |" \
  '| Absent, with a local `.claude/rules/` | 1 |' \
  '| Absent, no `.claude/rules/` | 1 |' \
  "| Could not be read | 0 |" \
  "| \`drift-repo\` | 1 | 1 | $((${#rules[@]} - 2)) | 1 | \`$r1\` |" \
  "| \`match-repo\` | 2 | 0 | $((${#rules[@]} - 2)) | 0 | - |" \
  "| \`.github\` | ${#rules[@]} | 0 | 0 | 0 | - |" \
  '`local-repo` (2 local)'; do
  has "$want" "$out" || fail "happy path: missing line: $want"$'\n'"$out"
  ok
done
has 'old-repo' "$(cat "$f/calls.log")" && fail "archived repo old-repo was requested"
ok

# --------------------------------------------------------- 2. read error
f="$work/err"; cp -R "$work/ok" "$f"
rm -f "$f/match-repo.json"; : >"$f/match-repo.500"
run "$f"
[ "$status" -eq 1 ] || fail "read error: expected exit 1, got $status"
ok
has '## Could not be read' "$out" || fail "read error: report lacks the 'Could not be read' table"$'\n'"$out"
ok
has '| `match-repo` | gh: Server Error (HTTP 500) |' "$out" || fail "read error: match-repo row missing"$'\n'"$out"
ok
has '| Drifted (org rule name present, content differs) | 1 |' "$out" || fail "read error: report was not printed in full"
ok
has '1 repo(s) could not be read' "$errout" || fail "read error: no ::error:: line: $errout"
ok

# ------------------------------------------------------ 3. no private repo
f="$work/public"; cp -R "$work/ok" "$f"
jq -c '.[] |= (.visibility = "public")' "$work/ok/repos.json" >"$f/repos.json"
run "$f"
[ "$status" -eq 1 ] || fail "no private repo: expected exit 1, got $status"
ok
has 'the token sees no private repo' "$errout" || fail "no private repo: no ::error:: line: $errout"
ok

# ------------------------------------------------- 4. source does not match
f="$work/source"; cp -R "$work/ok" "$f"
jq '.[0].sha = "0000000000000000000000000000000000000000"' "$work/ok/.github.json" >"$f/.github.json"
run "$f"
[ "$status" -eq 1 ] || fail "source mismatch: expected exit 1, got $status"
ok
has 'does not match its own' "$errout" || fail "source mismatch: no ::error:: line: $errout"
ok

echo "PASS: $NAME ($assertions assertion(s))"
