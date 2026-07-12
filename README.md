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
    skills/
    scripts/
    hooks/                      # Optional lifecycle hooks

codex/
  plugins/
    <plugin>/                   # Codex plugin implementations
      .codex-plugin/plugin.json
      skills/                   # Runtime-invocable $plugin:skill workflows
      commands/                 # Provider-parity reference documents
      scripts/
      hooks/                    # Optional lifecycle hooks
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

Install a plugin from that marketplace:

```bash
codex plugin add <plugin-name>@girishattri-plugins
```

Review bundled hooks when Codex prompts for trust; installing or enabling a
plugin does not automatically trust its lifecycle hooks.

Upgrade the configured marketplace after new plugin versions are published:

```bash
codex plugin marketplace upgrade girishattri-plugins
```

Start a new Codex session after installing or upgrading so the updated plugin
skills and tools are loaded. These trust and session-pickup behaviors are
documented in [OpenAI's Codex plugin guide](https://learn.chatgpt.com/docs/plugins).
Verify installed and enabled versions with:

```bash
codex plugin list --json
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

Refresh the configured marketplace, then update an installed plugin:

```bash
claude plugin marketplace update girishattri-plugins
claude plugin update <plugin-name>@girishattri-plugins
```

Repeat the second command for each installed plugin you want to update, then
restart Claude Code so it loads the updated plugin version.

For local development, add a checkout path instead:

```bash
claude plugin marketplace add /path/to/agent-plugins
```

## Development Notes

- Keep provider-specific manifests separate.
- Keep Claude command behavior aligned with the corresponding Codex skills and
  provider-parity command references.
- Codex exposes plugin skills as invocable `$plugin:skill` workflows. Treat
  `codex/plugins/<name>/commands/*.md` as provider-parity reference documents,
  and always ship a skill twin for runtime behavior.
- Codex hooks must live at `codex/plugins/<name>/hooks/hooks.json` (a plugin-root `hooks.json` is silently ignored by the runtime). Hook commands must use the runtime-provided `PLUGIN_ROOT`; never derive a plugin root from the session cwd or pin a marketplace-cache version.
- Codex skills resolve scripts relative to the selected installed `SKILL.md` source. They must not rely on `CODEX_PLUGIN_ROOT`, which is not guaranteed in model-launched shell commands.
- Interactive/destructive workflows use Codex `request_user_input` when that capability is available and fall back to a direct blocking question with default-cancel semantics. Claude keeps the matching `AskUserQuestion` flow.
- Shared ideas can be documented in `docs/`, but runtime files should remain provider-local.
- Generated logs such as `firebase-debug.log` are ignored and should not be committed.
- Run `bash scripts/validate-release.sh` before publishing plugin updates.
- `session-scheduler` is intentionally a file-backed ledger layered on `session-chat`; keep scheduling state out of the transport plugin.
