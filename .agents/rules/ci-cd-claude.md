---
trigger: glob
globs: '**/.github/workflows/**'
---
# Claude Reusable Workflow

Part of the CI/CD rule set; the call conventions and the `claude` topic grant are in ci-cd-workflows.md.

### Claude Workflow Inputs

`reusable-claude.yml` accepts these inputs for per-repo customization:

| Input | Type | Default | Description |
|-------|------|---------|-------------|
| `runner` | string | `ubuntu-slim` | Runner label |
| `claude_args` | string | `''` | Extra Claude CLI arguments, appended last. The workflow already passes `--model claude-opus-4-8 --effort medium`, `--max-turns`, `--allowedTools` and `--system-prompt`; change the turn budget and tool list through `max_turns` and `allowed_tools` |
| `max_turns` | number | `50` | Maximum agentic turns, passed as `--max-turns` and stated in the built-in system prompt |
| `allowed_tools` | string | *see workflow* | Comma-separated list passed verbatim as `--allowedTools`. The default covers the FVH stack: `Edit`, `Write`, `Bash(...)` for uv, pytest, python, ruff, bun, biome, node, just, pre-commit and make, and ten `mcp__github__*` issue tools. Setting the input replaces the whole default list; the action's own tag-mode tools (`Glob`, `Grep`, `LS`, `Read`, and git add/commit/push/rm) stay allowed regardless. Listing any `mcp__github__*` tool makes the action mount the GitHub MCP server |
| `timeout_minutes` | number | `45` | Job timeout in minutes |
| `additional_permissions` | string | `''` | Extra GitHub permissions for the action to request, one `scope: level` per line, appended after the built-in `actions: read` |
| `plugins` | string | `''` | Newline-separated Claude Code plugins to install (`name@marketplace`) |
| `plugin_marketplaces` | string | `''` | Newline-separated plugin marketplace Git URLs |

Secrets:
- `CLAUDE_CODE_OAUTH_TOKEN` — required. The org secret granted by the `claude` repository topic; see *The Claude token is granted by repository topic* in ci-cd-workflows.md.

Example — longer turn budget and job timeout for a large codebase:

```yaml
uses: ForumViriumHelsinki/.github/.github/workflows/reusable-claude.yml@main
with:
  max_turns: 80
  timeout_minutes: 60
secrets:
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

### Max-Turns Handoff

When Claude exhausts its turn budget, the workflow posts a continuation comment instead of failing silently:

1. Detects `error_max_turns` from the execution output
2. Posts a comment with progress summary, branch name (if partial work was pushed), and a continuation prompt
3. User replies "Continue where you left off @claude" to trigger a new run with full conversation context
4. The bot filter (`sender.type != 'Bot'`) prevents infinite loops

The workflow also injects a `--system-prompt` instructing Claude to commit and push partial progress early for multi-step tasks.
