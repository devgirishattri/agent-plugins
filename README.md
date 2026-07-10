# Claude and Codex Plugins

This repository contains provider-specific plugins for Claude Code and Codex. The plugin implementations are intentionally separated by provider so each runtime reads only the configuration format it understands.

## Plugins

| Plugin | Purpose |
|--------|---------|
| `session-manager` | List, search, and delete local agent session data |
| `session-chat` | Name tmux panes, send messages, and dispatch tasks between sessions |
| `session-scheduler` | Track and assign task ids across orchestrator, executor, and reviewer panes |
| `session-context` | Generate, list, load, and share session context snapshots |
| `creating-docs` | Create and update documentation using structured guidance and validation scripts |

## Repository Layout

```text
.claude-plugin/
  marketplace.json              # Claude marketplace metadata

.agents/
  plugins/
    marketplace.json            # Codex marketplace metadata

plugins/
  <plugin>/                     # Claude plugin implementations
    .claude-plugin/plugin.json
    commands/
    scripts/

codex/
  plugins/
    <plugin>/                   # Codex plugin implementations
      .codex-plugin/plugin.json
      commands/
      scripts/
```

## Provider Discovery

Claude and Codex use different marketplace roots and plugin manifests.

| Provider | Marketplace | Plugin Manifest |
|----------|-------------|-----------------|
| Claude | `.claude-plugin/marketplace.json` | `plugins/<name>/.claude-plugin/plugin.json` |
| Codex | `.agents/plugins/marketplace.json` | `codex/plugins/<name>/.codex-plugin/plugin.json` |

Codex does not read Claude plugin configuration as Codex plugins. When this repo is added as a Codex marketplace, Codex reads `.agents/plugins/marketplace.json`, then follows each entry's `source.path` to a Codex plugin directory. The current Codex marketplace points only to `./codex/plugins/<name>`.

Claude likewise reads the Claude marketplace and Claude manifests. It should not consume `.agents/plugins/marketplace.json` or `.codex-plugin/plugin.json`.

## Installation

### Codex

Add this repo as a Codex marketplace from GitHub:

```bash
codex plugin marketplace add https://github.com/devgirishattri/agent-plugins.git
```

Upgrade the configured marketplace after new plugin versions are published:

```bash
codex plugin marketplace upgrade girishattri-plugins
```

Reload Codex after upgrading so the running plugin registry uses the new cached version. Use `/reload-plugins` when available, or restart the Codex session. To verify the installed cache, inspect:

```bash
ls "$HOME/.codex/plugins/cache/girishattri-plugins/session-chat"
```

To upgrade all configured Git marketplaces:

```bash
codex plugin marketplace upgrade
```

For local development, add a checkout path instead:

```bash
codex plugin marketplace add /path/to/agent-plugins
```

### Claude

Add this repo as a Claude marketplace from GitHub:

```bash
claude plugin marketplace add https://github.com/devgirishattri/agent-plugins.git
```

Install a plugin from the marketplace:

```bash
claude plugin install <plugin-name>@girishattri-plugins
```

Upgrade all installed plugins to the latest marketplace versions:

```bash
claude plugin upgrade
```

For local development, add a checkout path instead:

```bash
claude plugin marketplace add /path/to/agent-plugins
```

## Development Notes

- Keep provider-specific manifests separate.
- Keep command behavior aligned across `plugins/<name>/commands/` and `codex/plugins/<name>/commands/`.
- Codex runtime surfaces (verified live 2026-06-11): **skills** are loaded and invocable (`$plugin:skill`); plugin `commands/*.md` are NOT loaded by the Codex runtime — treat them as reference docs mirroring the Claude commands, and always ship a skill twin for runtime behavior.
- Codex hooks must live at `codex/plugins/<name>/hooks/hooks.json` (a plugin-root `hooks.json` is silently ignored by the runtime). Hook commands must use the runtime-provided `PLUGIN_ROOT`; never derive a plugin root from the session cwd or pin a marketplace-cache version.
- Codex skills resolve scripts relative to the selected installed `SKILL.md` source. They must not rely on `CODEX_PLUGIN_ROOT`, which is not guaranteed in model-launched shell commands.
- Interactive/destructive workflows use Codex `request_user_input` when that capability is available and fall back to a direct blocking question with default-cancel semantics. Claude keeps the matching `AskUserQuestion` flow.
- Shared ideas can be documented in `docs/`, but runtime files should remain provider-local.
- Generated logs such as `firebase-debug.log` are ignored and should not be committed.
- Run `bash scripts/validate-release.sh` before publishing plugin updates.
- `session-scheduler` is intentionally a file-backed ledger layered on `session-chat`; keep scheduling state out of the transport plugin.

## Documentation


