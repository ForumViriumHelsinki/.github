#!/usr/bin/env bash
# The shipped .gitleaks.toml blocks FVH GCP identifiers from this public repo.
#
# deploy-values.md carried a real GCP project ID and Cloud SQL connection name
# until they were replaced with `my-project` / `my-instance`. The custom
# `fvh-gcp-project-id` rule keeps them out; this test runs that rule, from the
# shipped config, against fixtures.
#
# Assertions:
#   1. The shipped deploy-values.md, with FVH-shaped identifiers in place of
#      the placeholders, is flagged on both lines by fvh-gcp-project-id.
#   2. Other FVH-shaped identifiers (another fvh-project-*, another
#      <project>:europe-north1:<instance>) are flagged.
#   3. The placeholder forms pass.
#   4. The rule sources and every generated copy pass.
#
# Needs the gitleaks binary: lint.yml installs it, `mise` or brew locally.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

command -v gitleaks >/dev/null || { echo "FAIL: gitleaks not on PATH" >&2; exit 1; }
[ -f .gitleaks.toml ] || { echo "FAIL: .gitleaks.toml missing" >&2; exit 1; }

# Fixture identifiers are assembled at run time and are not real FVH IDs, so
# this file itself passes the tree-wide gitleaks scan in lint.yml.
fvh_prefix="fvh-project"
fvh_id="${fvh_prefix}-sample"
region="europe-north1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
assertions=0

# Prints the rule IDs gitleaks reports for a path, one per finding.
findings() {
  local report="$work/report.json"
  rm -f "$report"
  gitleaks dir --no-banner --log-level error --config .gitleaks.toml \
    --report-format json --report-path "$report" "$1" >/dev/null 2>&1 || true
  [ -f "$report" ] || { echo "FAIL: gitleaks wrote no report for $1" >&2; exit 1; }
  jq -r '.[].RuleID' "$report"
}

expect_count() { # path, expected fvh-gcp-project-id count, label
  local got
  got="$(findings "$1" | grep -c '^fvh-gcp-project-id$' || true)"
  assertions=$((assertions + 1))
  if [ "$got" -ne "$2" ]; then
    echo "FAIL: $3: expected $2 fvh-gcp-project-id finding(s), got $got" >&2
    exit 1
  fi
}

# 1. Put FVH-shaped identifiers back into the shipped rule text.
src=.rulesync/rules/deploy-values.md
placeholders="$(grep -c 'my-project' "$src" || true)"
[ "$placeholders" -ge 2 ] || { echo "FAIL: expected >=2 my-project placeholders in $src, found $placeholders" >&2; exit 1; }
mkdir "$work/prefix"
sed -e "s/my-project:europe-north1:my-instance/${fvh_id}:${region}:sample-db/" \
    -e "s/@my-project\\.iam/@${fvh_id}.iam/" \
    "$src" > "$work/prefix/deploy-values.md"
expect_count "$work/prefix" 2 "deploy-values.md with FVH identifiers"

# 2. Other identifiers of the same shape.
mkdir "$work/bad"
cat > "$work/bad/other.md" <<EOF
serviceAccount: app@${fvh_prefix}-staging.iam.gserviceaccount.com
connection: "sample-project:${region}:db-1"
EOF
expect_count "$work/bad" 2 "other FVH-shaped identifiers"

# 3. Placeholders.
mkdir "$work/good"
cat > "$work/good/placeholder.md" <<'EOF'
serviceAccount: my-app@my-project.iam.gserviceaccount.com
connection: "my-project:europe-north1:my-instance"
EOF
expect_count "$work/good" 0 "placeholder forms"

# 4. Shipped rule sources and generated copies.
for d in .rulesync/rules .claude/rules .agents/rules .cursor/rules .github/instructions; do
  [ -d "$d" ] || { echo "FAIL: expected rules dir $d" >&2; exit 1; }
  expect_count "$d" 0 "shipped $d"
done

echo "PASS: public-identifiers ($assertions assertion(s))"
