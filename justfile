# ForumViriumHelsinki/.github — reusable workflows and org defaults
# `just lint` and `just test` run the same commands as .github/workflows/lint.yml.

set positional-arguments

# Tool pins. Each must equal its lint.yml counterpart (the tool-pins test
# checks this); renovate.json bumps both together.
actionlint_version := "1.7.12"
gitleaks_version := "8.30.1"
ruff_version := "0.16.9"
rulesync_version := "40.2.0"

# List recipes
default:
    @just --list

# YAML validity, actionlint, gitleaks, rulesync drift, and ruff format of the rule sources (same checks as CI)
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
    if command -v mise >/dev/null 2>&1; then
        gl=(mise exec "aqua:gitleaks/gitleaks@{{ gitleaks_version }}" -- gitleaks)
    elif command -v gitleaks >/dev/null 2>&1; then
        gl=(gitleaks)
    else
        echo "gitleaks not found: install mise or gitleaks {{ gitleaks_version }}" >&2
        exit 1
    fi
    "${gl[@]}" dir --no-banner --redact --config .gitleaks.toml .
    npx --yes "rulesync@{{ rulesync_version }}" generate --check
    # Python blocks in the rule sources, as consumers' ruff formats them. No
    # fallback to a ruff on PATH: another version formats Markdown differently.
    if command -v uvx >/dev/null 2>&1; then
        rf=(uvx "ruff@{{ ruff_version }}")
    elif command -v mise >/dev/null 2>&1; then
        rf=(mise exec "aqua:astral-sh/ruff@{{ ruff_version }}" -- ruff)
    else
        echo "ruff not found: install uv or mise (ruff {{ ruff_version }} is run through either)" >&2
        exit 1
    fi
    "${rf[@]}" format --check --diff --isolated --line-length 88 .rulesync/rules

# Run lint.yml's consumer sync path step (the shipped rulesync fetch + generate of reusable-sync-ai-rules.yml) in a scratch repo; needs network and a GitHub token
sync-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    step='Consumer sync path (fetch + generate)'
    body=$(STEP="$step" yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .run // ""' .github/workflows/lint.yml)
    [ -n "$body" ] || { echo "no step named '$step' in lint.yml" >&2; exit 1; }
    eval "$(STEP="$step" yq '.jobs.lint.steps[] | select(.name == strenv(STEP)) | .env | del(.GITHUB_TOKEN) | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' .github/workflows/lint.yml)"
    GITHUB_TOKEN=${GITHUB_TOKEN:-$(gh auth token)} bash --noprofile --norc -eo pipefail -c "$body"

# Regenerate the tool-specific rule copies from .rulesync/ with the pinned rulesync
rules-generate:
    npx --yes "rulesync@{{ rulesync_version }}" generate

# Run every test under .github/tests/, or only the named ones
test *names:
    @bash .github/tests/run.sh "$@"
