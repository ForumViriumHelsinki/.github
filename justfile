# ForumViriumHelsinki/.github — reusable workflows and org defaults
# `just lint` and `just test` run the same commands as .github/workflows/lint.yml.

set positional-arguments

actionlint_version := "1.7.12"

# List recipes
default:
    @just --list

# YAML validity, actionlint, gitleaks, and rulesync drift (same checks as CI)
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    shopt -s nullglob
    files=(.github/workflows/*.yml .github/workflows/*.yaml workflow-templates/*.yml workflow-templates/*.yaml)
    [ "${#files[@]}" -gt 0 ] || { echo "no workflow or template files found"; exit 1; }
    for f in "${files[@]}"; do
        yq -e 'tag == "!!map"' "$f" >/dev/null || { echo "INVALID YAML: $f"; exit 1; }
    done
    echo "All ${#files[@]} workflow and template files are valid YAML."
    if command -v mise >/dev/null 2>&1; then
        al=(mise exec "aqua:rhysd/actionlint@{{ actionlint_version }}" -- actionlint)
    elif command -v actionlint >/dev/null 2>&1; then
        al=(actionlint)
    else
        echo "actionlint not found: install mise or actionlint {{ actionlint_version }}" >&2
        exit 1
    fi
    "${al[@]}" -shellcheck= -oneline "${files[@]}"
    echo "actionlint: clean"
    # Scans the working tree, including untracked scratch under tmp/.
    command -v gitleaks >/dev/null || { echo "gitleaks not found: mise use -g aqua:gitleaks/gitleaks" >&2; exit 1; }
    gitleaks dir --no-banner --redact --config .gitleaks.toml .
    npx --yes rulesync@latest generate --check

# Run every test under .github/tests/, or only the named ones
test *names:
    @bash .github/tests/run.sh "$@"
