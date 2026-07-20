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
| `chronos` | Inject fresh current date/time context with every prompt for time/day-aware agents |

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

## Session Chat Configuration

The Claude and Codex `session-chat` plugins share the same transport
configuration except for two Claude-only hook limits noted below. Export
long-lived settings in the shell that starts Claude Code or Codex, then restart
or reload the session. Command-scoped exports affect only that invocation.

### Shared variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SESSION_CHAT_INCOMING_MODE` | `notify` | Controls receiver behavior: `notify`, `assist`, `auto`, or `off`. Orchestration normally uses `auto` or `assist`. |
| `SESSION_CHAT_VERIFY_TIMEOUT_MS` | `4000` | Maximum marker-verification wait for each live-send attempt. |
| `SESSION_CHAT_SETTLE_MS` | `300` | Delay after Enter before another sender may use the target pane. |
| `SESSION_CHAT_SEND_MAX_LEN` | `1024` | Maximum single-line payload length for `send`; use `dispatch` for larger or multiline content. |
| `SESSION_CHAT_SEND_RETRIES` | `2` | Retries after live marker-verification timeouts; total attempts are retries plus one. |
| `SESSION_CHAT_RETRY_BACKOFF_MS` | `200` | Linear retry-backoff base in milliseconds. |
| `SESSION_CHAT_LOCK_TIMEOUT_MS` | Derived | Per-target send-lock wait budget. When unset, it is derived from the send budget and resets when the lock holder changes; an explicitly configured value is a hard cap. |
| `SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS` | Derived | Delay before a recipient may surface a pre-live durable queue row. The default is the lock budget plus one send budget plus 1000 ms. |
| `SESSION_CHAT_RECENT_ID_TTL_MS` | `600000` | How long surfaced message IDs suppress duplicate live and queued arrivals. |
| `SESSION_CHAT_DISPATCH_INLINE_MAX` | `6000` | Maximum trusted dispatch-body characters inlined in `auto` mode. |
| `SESSION_CHAT_ARCHIVE_RETENTION_DAYS` | `30` | Retention for daily searchable message-archive files. |
| `SESSION_CHAT_SKIP_VERIFY` | Unset (`0`) | Set to `1` to skip live marker verification. This weakens delivery guarantees. |
| `SESSION_CHAT_ALLOW_SHELL_TARGET` | `0` | Set to `1` to permit sending to panes at a shell prompt. Use only for deliberate shell targets because the message may execute as shell input. |
| `SESSION_CHAT_PANE_NAME` | Unset | Explicitly supplies the sender pane name and bypasses self-name lookup, primarily for sandboxed tmux environments. |
| `SESSION_CHAT_TARGET_MESSAGES_DIR` | Auto-detected | Overrides the local mailbox and every target mailbox. Export the same absolute directory in all participating panes before starting their agents so live dispatch trust and queued recovery use one root. |
| `SESSION_CHAT_PRIORITY` | `normal` | Queue priority: `high` or `1` surfaces before normal messages. Prefer the `--priority` command option. |
| `SESSION_CHAT_TTL_MS` | `0` | Queue expiry in milliseconds; `0` means no expiry. Prefer the `--ttl` command option, which accepts minutes. |

### Provider-specific variables

| Variable | Provider | Default | Purpose |
|----------|----------|---------|---------|
| `CODEX_HOME` | Both, for Codex storage | `$HOME/.codex` | Locates Codex sessions and the default Codex `messages/` directory when `SESSION_CHAT_TARGET_MESSAGES_DIR` is unset. |
| `CLAUDE_HOME` | Both, for Claude storage | `$HOME/.claude` | Locates the default Claude `messages/` directory used by normal transport and cross-runtime routing when `SESSION_CHAT_TARGET_MESSAGES_DIR` is unset. |
| `SESSION_CHAT_SURFACE_MAX` | Claude only | `9000` | Maximum combined queued-message surface budget before the hook stops selecting additional rows. |
| `SESSION_CHAT_REPLY_SCAN_BYTES` | Claude only | `4096` | Maximum prefix read from a trusted dispatch file when scanning for reply-correlation tokens. |

`HOME` supplies the standard fallback roots, and `TMPDIR` selects the parent
for private temporary and send-lock directories. The runtime supplies `TMUX`,
`TMUX_PANE`, and the provider plugin-root variables; these are integration
inputs, not session-chat user settings.

## Other Plugin Configuration

The remaining plugins expose the variables below. A `Yes` in both provider
columns means both implementations read the variable for the stated purpose;
provider-specific differences are called out explicitly.

### Session context

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `SESSION_CONTEXT_HOME` | Yes | Yes | Required (inherited) | Snapshot store root. Must already be present in the environment a pane/agent inherits at startup; context commands and skills never export or derive it, and most scripts fail closed when it is unset. Claude's `context-search` uses it only as an override for the current project's store (its cross-project scan runs regardless), while Codex's requires it. The SessionStart detection hook derives a git-root default for its own banner only. |
| `SESSION_CONTEXT_STALE_DAYS` | Yes | Yes | `7` | Age at which `context-load` warns that a snapshot is stale. |
| `SESSION_CHAT_ROOT_OVERRIDE` | Yes | Yes | Unset | Development/integration override for locating the `session-chat` dependency used by `context-share`. |
| `SESSION_CHAT_PLUGIN_ROOT` | No | Yes | Unset | Additional Codex-only explicit locator for the `session-chat` dependency. |

The core context-store variable name and inherited-at-startup contract are
shared, but `context-search` unset behavior differs as noted above.
`SESSION_CHAT_PLUGIN_ROOT` is a Codex-only locator; both providers support
`SESSION_CHAT_ROOT_OVERRIDE`. As with the scheduler homes below,
launcher/parent-shell configuration establishes `SESSION_CONTEXT_HOME` before
an agent starts; agent-facing context instructions never combine environment
setup with helper execution, and `context-share` (which performs nested
session-chat/tmux transport) follows the same first-attempt scoped-escalation
rule as the scheduler's transport-bearing helpers.

### Session scheduler

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `SESSION_SCHEDULER_HOME` | Yes | Yes | Required (inherited) | Shared task ledger root. Must already be present in the environment a pane/agent inherits at startup; scheduler commands and skills never export or derive it, and scripts fail closed when it is unset. |
| `SESSION_CONTEXT_HOME` | Yes | Yes | Required (inherited) | Resolves an attached session-context snapshot for the scheduler under the same contract: inherited at agent startup, required whenever a context is attached. |
| `SESSION_SCHEDULER_STALE_MINUTES` | Yes | Yes | `30` | Age after which assigned or review tasks are marked `STALE`. |
| `SESSION_SCHEDULER_FORCE` | Yes | Yes | `0` | Set to `1` to permit otherwise illegal status transitions. Prefer the `--force` option. |
| `SESSION_CHAT_ROOT_OVERRIDE` | Yes | Yes | Unset | Development/integration override for locating the scheduler's `session-chat` dependency. |
| `SESSION_CHAT_PLUGIN_ROOT` | No | Yes | Unset | Additional Codex-only explicit locator for `session-chat`. |
| `SESSION_SCHEDULER_SKIP_VERSION_CHECK` | Yes | No | `0` | Claude-only escape hatch that bypasses the minimum `session-chat` version check when set to `1`. |

The scheduler also reads the already-documented
`SESSION_CHAT_INCOMING_MODE` in its doctor command. Scheduler storage, context
attachment, stale detection, and force behavior are shared; dependency-locator
and version-check overrides are not fully aligned.

Environment ownership for the two scheduler homes is split by role:
launcher/parent-shell configuration establishes `SESSION_SCHEDULER_HOME` and
`SESSION_CONTEXT_HOME` before an agent process starts; an already-running agent
invokes each scheduler helper as a single literal Bash segment using those
inherited values. Direct human script use may set the variables in the parent
shell first, but generated agent instructions (skills, commands, assignment and
review packets) never combine environment setup with helper execution — packets
repeat the absolute homes only as provenance and relaunch guidance.

The four transport-bearing helpers (`task-assign`, `task-review`, `task-done`,
`task-block`) additionally perform nested session-chat/tmux transport. A
sandboxed runtime (e.g. Codex) should grant scoped escalation/approval for the
exact installed helper on its first invocation; the helpers never self-escalate,
and agents must not bypass a transport denial with wrappers or command
composition. A notification that fails after a completed `done`/`blocked`
transition is reported as an explicit partial success — the transition is never
rerun and `--force` is never a notification repair.

### Session manager and provider homes

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `CLAUDE_HOME` | Partial | Not applicable | `$HOME/.claude` | Claude `session-stats` uses it, but Claude list, search, and delete scripts currently use `$HOME/.claude` directly. Claude session-context cross-project search also honors it. |
| `CODEX_HOME` | Not applicable | Yes | `$HOME/.codex` | Codex session-manager uses it for session and state storage. Codex session-context and session-scheduler also use it for session discovery, message storage, and plugin-cache lookup. |
| `AGENT_PLUGINS_TIME_ZONE` | Yes | Yes | `Asia/Kolkata` | IANA timezone used by Chronos and plugin-generated timestamps. |

Session-manager therefore has equivalent provider-home intent but not literal or
behavioral parity: Codex consistently honors `CODEX_HOME`, while most Claude
session-manager operations do not honor `CLAUDE_HOME`.

### Chronos

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `CHRONOS_INTERVAL_MIN` | Yes | No | `5` | Throttle window in minutes for the Claude-only PreToolUse refresh hook. Within the window, PreToolUse emits nothing; UserPromptSubmit always injects a fresh timestamp regardless. |

Chronos injects a single compact `Current time: …` line in the configured
timezone (weekday, time, zone, and numeric UTC offset computed from one captured
epoch) as model context. The default is IST (`Asia/Kolkata`). The Claude implementation injects on every user prompt and refreshes
mid-turn via the throttled PreToolUse hook; the Codex implementation is
per-prompt only (UserPromptSubmit), so it has no throttle variable.

### Creating docs

`creating-docs` exposes no plugin-specific user environment variables. Its
plugin-root values and validator target directories are runtime or command
inputs rather than persistent configuration.

Standard shell/runtime inputs such as `HOME`, `TMPDIR`, `TMUX`, `TMUX_PANE`,
`PLUGIN_ROOT`, and `CLAUDE_PLUGIN_ROOT` are not plugin-specific customization
variables. Test-only fault-injection variables and shell-local implementation
variables are intentionally omitted.

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
