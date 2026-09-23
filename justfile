# ForumViriumHelsinki/.github — reusable workflows and org defaults
# `just lint` and `just test` run the same commands as .github/workflows/lint.yml.

set positional-arguments

actionlint_version := "1.7.12"

# List recipes
default:
    @just --list

# YAML validity, actionlint, and rulesync drift (same checks as CI)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    for f in .github/workflows/*.yml workflow-templates/*.yml; do
        yq -e 'tag == "!!map"' "$f" >/dev/null || { echo "INVALID YAML: $f"; exit 1; }
    done
    echo "All workflow and template files are valid YAML."
    if command -v mise >/dev/null 2>&1; then
        al=(mise exec "aqua:rhysd/actionlint@{{ actionlint_version }}" -- actionlint)
    elif command -v actionlint >/dev/null 2>&1; then
        al=(actionlint)
    else
        echo "actionlint not found: install mise or actionlint {{ actionlint_version }}" >&2
        exit 1
    fi
    "${al[@]}" -shellcheck= -oneline .github/workflows/*.yml workflow-templates/*.yml
    echo "actionlint: clean"
    npx --yes rulesync@latest generate --check

# Run every test under .github/tests/, or only the named ones
test *names:
    @bash .github/tests/run.sh "$@"
