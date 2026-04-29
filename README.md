# Claude and Codex Plugins

This repository contains provider-specific plugins for Claude Code and Codex. The plugin implementations are intentionally separated by provider so each runtime reads only the configuration format it understands.

## Plugins

| Plugin | Purpose |
|--------|---------|
| `session-manager` | List, search, and delete local agent session data |
| `session-chat` | Name tmux panes, send messages, and dispatch tasks between sessions |
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

For local development, add a checkout path instead:

```bash
codex plugin marketplace add /path/to/agent-plugins
```

### Claude

Use the repository as a Claude plugin marketplace. The Claude marketplace file is:

```text
.claude-plugin/marketplace.json
```

It points to the Claude plugin implementations under `plugins/`.

## Development Notes

- Keep provider-specific manifests separate.
- Keep command behavior aligned across `plugins/<name>/commands/` and `codex/plugins/<name>/commands/`.
- Shared ideas can be documented in `docs/`, but runtime files should remain provider-local.
- Generated logs such as `firebase-debug.log` are ignored and should not be committed.

## Documentation

- `docs/TODO.md` tracks planned plugin work.

