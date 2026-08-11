# Claude and Codex Plugins

[![validate](https://github.com/devgirishattri/agent-plugins/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/devgirishattri/agent-plugins/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

This repository contains provider-specific plugins for Claude Code and Codex. The plugin implementations are intentionally separated by provider so each runtime reads only the configuration format it understands.

## Plugins

Every plugin below ships for both providers at the same version number.

| Plugin | Version | Purpose |
|--------|---------|---------|
| `session-manager` | 1.7.4 | List, search, and delete local agent session data |
| `session-chat` | 0.17.7 | Name tmux panes, send messages, and dispatch tasks between sessions |
| `session-scheduler` | 0.5.11 | Track and assign task ids across orchestrator, executor, and reviewer panes |
| `knowledge` | 0.3.6 | Unified taxonomy tooling for durable project knowledge: docs, memory, and context snapshots in one plugin. Adds a native memory store with consolidation, promotion, deterministic search/recall, a backlink graph, and a read-only cross-store doctor. Absorbs the retired `session-context` and `creating-docs` |
| `session-workspace` | 0.1.5 | Config-driven tmux workspace engine: one shared engine for session, window, and pane lifecycle, replacing per-project `workspace.sh` launchers with a versioned `.agent-workspace/workspace.json` |
| `chronos` | 0.1.1 | Inject fresh current date/time context with every prompt for time/day-aware agents |

Versions here track `.claude-plugin/marketplace.json` and
`.agents/plugins/marketplace.json`, which `scripts/validate-release.sh` keeps in
step with each plugin manifest.

## Requirements

Supported platforms are macOS and Linux; `session-manager` also runs on Windows
under WSL. The scripts target bash 3.2 so they work with the bash macOS ships.

| Dependency | Needed by | Hard or optional |
|------------|-----------|------------------|
| `bash` 3.2+ | All | Hard |
| `jq` | `session-scheduler`, `session-workspace` | Hard. Both refuse to run without it. |
| `jq` | `chronos` | Optional. Falls back to hand-built JSON when absent. |
| `tmux` | `session-chat`, `session-scheduler`, `session-workspace` | Hard. These coordinate real panes. |
| `tmux` | `knowledge` | Optional. Only for pane-identity provenance; `KNOWLEDGE_PANE_NAME` substitutes. |
| `git` | `knowledge` | Hard. Store resolution and `init` require a repository. |
| `python3` | `knowledge` doctor, `session-chat` message surfacing | Optional. Both degrade rather than fail. |

`session-manager` and `chronos` need nothing beyond bash.

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

## Setup

Installing a plugin is not always enough to make it work. This section covers
what each one needs after installation. Full variable reference is in
[Session Chat Configuration](#session-chat-configuration) and
[Other Plugin Configuration](#other-plugin-configuration) below.

### Shared environment

Two variables must be exported **before** an agent process starts, because the
panes and agents inherit them and the scripts never derive or export them
themselves:

```bash
export SESSION_CONTEXT_HOME="$HOME/.agent-context"     # knowledge context snapshots
export SESSION_SCHEDULER_HOME="$HOME/.agent-tasks"     # session-scheduler task ledger
```

The paths are yours to choose; only the variable names are fixed. Set them in
the shell that launches Claude Code or Codex, or in your shell profile. Scripts
that need them fail closed with an explicit error when they are unset rather
than guessing a path, so a missing export surfaces as a clear failure instead of
silent misbehavior.

A project using `session-workspace` does not set these by hand. Listing
`scheduler` or `contexts` in the config's `stores.pin` is what exports
`SESSION_SCHEDULER_HOME` and `SESSION_CONTEXT_HOME` (and `messages` exports
`SESSION_CHAT_TARGET_MESSAGES_DIR`) into every pane the engine launches. Those
three names are rejected if written directly into an `env.groups` block, so
`stores.pin` stays their only source of truth.

### session-manager

No setup. It reads the session data your runtime already writes.

### chronos

No setup. Its hooks inject the current time once the plugin is enabled. Set
`AGENT_PLUGINS_TIME_ZONE` to a valid IANA zone to change from the `Asia/Kolkata`
default.

### knowledge

The memory store is per repository and must be created once, from inside the
repository:

```
/knowledge:init
```

That runs a plan/apply pair: it proposes the `.gitignore` line covering the
store, then creates `.agents/memory/` with an empty `MEMORY.md` at `0700`/`0600`.
It refuses to run outside a git repository, and re-running it is a no-op. Until
a store exists, the search, recall, and remember surfaces have nothing to read.

Docs and context surfaces work without a store. Context snapshots additionally
need `SESSION_CONTEXT_HOME`.

Automatic recall and automatic capture are **off** on a fresh install and are
enabled by different mechanisms:

- **Recall** is an environment gate. `KNOWLEDGE_AUTO_RECALL=1` enables injection
  at session start and on each prompt (`session` or `prompt` selects just one).
  `KNOWLEDGE_AUTO_RECALL_GRAPH=1` additionally pulls in backlink neighbors and
  is deliberately strict, accepting only `1`, `yes`, `on`, or `true`.
- **Capture** is a hook gate, not a variable. The retired `KNOWLEDGE_AUTO_CAPTURE`
  variable governs nothing. On Claude you enable capture by adding the opt-in
  `type: "prompt"` Stop-hook snippet from
  `plugins/knowledge/assets/capture-stop-hook.md` to your user or project
  `settings.json`. The hook's presence is the opt-in.

`plugins/knowledge/assets/recall-snippet.md` holds a short instruction block you
can paste into `CLAUDE.md` or `AGENTS.md` so agents query the store before
substantive work.

### session-chat

Needs tmux. A pane must have a name before it can send or receive, since names
are the addresses:

```
/whoami <name>
```

Each participating pane sets its own. Delivery behavior on the receiving side is
controlled by `SESSION_CHAT_INCOMING_MODE`, which defaults to `notify`;
orchestration setups normally want `auto` or `assist`. All panes that need to
exchange messages must agree on one mailbox root, so if you override
`SESSION_CHAT_TARGET_MESSAGES_DIR`, export the same absolute path in every pane
before its agent starts.

### session-scheduler

Needs tmux, `jq`, `SESSION_SCHEDULER_HOME`, and a working `session-chat` at
**0.13.0 or newer**, which it enforces at runtime. It layers a file-backed
ledger on that transport, so set up `session-chat` first and confirm panes can
actually message each other before assigning tasks. Attaching a context to a
task also requires `SESSION_CONTEXT_HOME`.

### session-workspace

Needs tmux and `jq`. Setup is once per machine, then once per project.

Per machine, put the dispatcher on `PATH`:

```
/workspace-install
```

That copies the plugin's `templates/workspace-dispatcher.sh` to
`~/.local/bin/workspace` (override with `--target`). It is idempotent and is
also how you refresh the copy after a plugin update, which matters because the
dispatcher lives outside the versioned plugin cache and can otherwise go stale.

Per project, create two things at the repository root:

1. `.agent-workspace/workspace.json`, the versioned config describing sessions,
   panes, per-role models and grants, exported coordination stores, and secrets.
2. `workspace.sh`, a bootstrap shim copied from the plugin's
   `templates/workspace.sh`. It resolves `SESSION_WORKSPACE_CONFIG` and
   `SESSION_WORKSPACE_PLUGIN_ROOT` and execs the engine. It holds no project
   logic, and project-specific behavior belongs in the JSON rather than here.

Then check the config and preview the plan before touching tmux. Both are
read-only:

```
/workspace-doctor
/workspace-plan
```

`/workspace-start` brings the workspace up, creating only what is missing.
`/workspace-stop`, `/workspace-restart`, and adopting existing unmanaged panes
are gated behind explicit `--confirmed` flags. The config schema is documented
in `plugins/session-workspace/README.md`.

### Hooks and restarts

`chronos`, `knowledge`, and `session-chat` register lifecycle hooks
(`UserPromptSubmit` and `PreToolUse` for chronos; `SessionStart`,
`UserPromptSubmit`, and `Stop` for the other two). Codex prompts for trust
before running a plugin's hooks, and installing or enabling a plugin does not
grant that trust on its own. Restart the session after installing or updating a
plugin so the runtime loads the new code and hooks.

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

### Knowledge (context snapshots)

These variables keep the `SESSION_CONTEXT_*` names they had under the retired
`session-context` plugin, but they are now read by `knowledge`.

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
review packets) never combine environment setup with helper execution. Packets
repeat the absolute homes only as provenance and relaunch guidance.

The four transport-bearing helpers (`task-assign`, `task-review`, `task-done`,
`task-block`) additionally perform nested session-chat/tmux transport. A
sandboxed runtime (e.g. Codex) should grant scoped escalation/approval for the
exact installed helper on its first invocation; the helpers never self-escalate,
and agents must not bypass a transport denial with wrappers or command
composition. A notification that fails after a completed `done`/`blocked`
transition is reported as an explicit partial success: the transition is never
rerun and `--force` is never a notification repair.

### Session manager and provider homes

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `CLAUDE_HOME` | Partial | Not applicable | `$HOME/.claude` | Claude `session-stats` uses it, but Claude list, search, and delete scripts currently use `$HOME/.claude` directly. Claude knowledge context cross-project search also honors it. |
| `CODEX_HOME` | Not applicable | Yes | `$HOME/.codex` | Codex session-manager uses it for session and state storage. Codex knowledge (context surfaces) and session-scheduler also use it for session discovery, message storage, and plugin-cache lookup. |
| `AGENT_PLUGINS_TIME_ZONE` | Yes | Yes | `Asia/Kolkata` | Validated IANA timezone used by Chronos and plugin-generated timestamps. Read by `chronos`, `session-scheduler`, and `knowledge`. `session-workspace` gives it no special handling: a project may pin it like any other value in its `workspace.json` env group, but the engine supplies no default and performs no timezone validation of its own. |

Session-manager therefore has equivalent provider-home intent but not literal or
behavioral parity: Codex consistently honors `CODEX_HOME`, while most Claude
session-manager operations do not honor `CLAUDE_HOME`.

### Session workspace

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `SESSION_WORKSPACE_CONFIG` | Yes | Yes | Discovered | Explicit path to the project's `.agent-workspace/workspace.json`. The bootstrap shim exports it; set it directly to drive a config outside the current project root. |
| `SESSION_WORKSPACE_PLUGIN_ROOT` | Yes | Yes | Resolved | Explicit engine root, used by the bootstrap shim and the machine-wide dispatcher when the installed plugin cannot be located by the normal search. |
| `SESSION_WORKSPACE_SOURCE_TREE_DIR` | Yes | Yes | Unset | Development override for the sibling-checkout search used to resolve the engine from a source tree instead of an installed copy. |
| `SESSION_WORKSPACE_LOCK_TIMEOUT` | Yes | Yes | `30` | Seconds to wait for the tmux lifecycle lock before giving up. |
| `SESSION_WORKSPACE_STOP_GRACE_SECONDS` | Yes | Yes | `5` | Grace period given to a pane's agent to exit before `workspace-stop` escalates. |
| `SESSION_WORKSPACE_ATTACH_DRY_RUN` | Yes | Yes | `0` | Set to `1` to skip the terminal attach step. Intended for tests and automation. |

All behavior lives in the plugin engine. An adopting project contributes only a
versioned `.agent-workspace/workspace.json` and a bootstrap `workspace.sh` shim
that resolves the two locator variables and execs the engine; the shim holds no
project logic. Lifecycle verbs are exposed as Claude commands (`/workspace-start`,
`/workspace-stop`, `/workspace-restart`, `/workspace-reconcile`,
`/workspace-status`, `/workspace-plan`, `/workspace-doctor`,
`/workspace-install`) and as matching Codex skills. `plan` and `doctor` mutate
nothing; destructive and adopting paths are gated behind explicit `--confirmed`
flags. Secrets declared in the config are handed to panes as a private `0600`
temp file passed by path, never through `send-keys` or tmux metadata. See
`plugins/session-workspace/README.md` for the config schema.

### Chronos

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `CHRONOS_INTERVAL_MIN` | Yes | No | `5` | Throttle window in minutes for the Claude-only PreToolUse refresh hook. Within the window, PreToolUse emits nothing; UserPromptSubmit always injects a fresh timestamp regardless. |

Chronos injects a single compact `Current time: …` line in the configured
timezone (weekday, time, zone, and numeric UTC offset computed from one captured
epoch) as model context. The default is IST (`Asia/Kolkata`). The Claude implementation injects on every user prompt and refreshes
mid-turn via the throttled PreToolUse hook; the Codex implementation is
per-prompt only (UserPromptSubmit), so it has no throttle variable.

### Knowledge (docs and memory)

The `knowledge` plugin's docs workflows (absorbed from the retired
`creating-docs`) expose no plugin-specific user environment variables. Its
plugin-root values and validator target directories are runtime or command
inputs rather than persistent configuration. Memory-store surfaces honor
`KNOWLEDGE_MEMORY_HOME` (explicit store target) and
`KNOWLEDGE_INBOX_RETENTION_DAYS` (capture-inbox retention, default 30).

Standard shell/runtime inputs such as `HOME`, `TMPDIR`, `TMUX`, `TMUX_PANE`,
`PLUGIN_ROOT`, and `CLAUDE_PLUGIN_ROOT` are not plugin-specific customization
variables. Test-only fault-injection variables and shell-local implementation
variables are intentionally omitted.

Knowledge automatic recall is opt-in and independent of Claude/Codex native
memory. `KNOWLEDGE_AUTO_RECALL` selects session and/or prompt injection;
prompt seeds need a strong lexical field score or two distinct prompt terms.
`KNOWLEDGE_AUTO_RECALL_GRAPH` is a separate strict gate (only `1`, `yes`,
`on`, or `true`) and adds at most two inbound/outbound depth-one `[[slug]]`
neighbors from the top two direct seeds, within the overall result and output
budget caps. Output labels direct lexical versus related-via-seed results;
invalid graph values and helper failures fail closed without breaking hooks.

Once automatic recall and capture are enabled, these tunables bound them. The
defaults are chosen to keep injected context small, so raise them deliberately.

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `KNOWLEDGE_AUTO_RECALL_LIMIT` | Yes | Yes | `5` | Maximum recalled memories injected per pass. |
| `KNOWLEDGE_AUTO_RECALL_TERMS` | Yes | Yes | `4` | Maximum salient prompt terms queried per pass. |
| `KNOWLEDGE_AUTO_RECALL_BUDGET` | Yes | Yes | `4000` | Character cap on the injected recall block. |
| `KNOWLEDGE_AUTO_CAPTURE_LIMIT` | Yes | Yes | `3` | Maximum candidates accepted into the capture inbox per pass. |
| `KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING` | Yes | Yes | `20` | Skip the whole capture pass once the inbox holds this many pending items. |
| `KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES` | Yes | Yes | `4096` | Hard per-candidate raw-byte cap. |
| `KNOWLEDGE_CONSOLIDATE_NUDGE` | Yes | Yes | Unset (off) | Off unless set to a non-empty value other than `0`, `no`, `off`, or `false`. When on, reminds the session to run `/knowledge:consolidate` while the capture inbox is non-empty. Silent on any error. |
| `KNOWLEDGE_PANE_NAME` | Yes | Yes | Auto-detected | First entry in the writer's pane-identity resolution chain, used for role detection and write provenance. Set it where tmux pane lookup is unavailable; writers fail closed with `unresolved pane identity` rather than guessing. |

`memory-write.sh` also reads several `KNOWLEDGE_TEST_*` fault-injection
variables. Those are test harness knobs, not user configuration, and are
deliberately left out of the table above.

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
    agents/                     # Optional subagent definitions
    hooks/                      # Optional lifecycle hooks
    templates/                  # Optional user-copied starter files

codex/
  plugins/
    <plugin>/                   # Codex plugin implementations
      .codex-plugin/plugin.json
      skills/                   # Runtime-invocable $plugin:skill workflows
      commands/                 # Provider-parity reference documents
      scripts/
      hooks/                    # Optional lifecycle hooks
      templates/                # Optional user-copied starter files

scripts/
  validate-release.sh           # Pre-publish metadata and parity validation
  test-provider-parity.sh       # Cross-provider scheduler/context parity test

.github/workflows/validate.yml  # CI: release validation, per-plugin smoke
                                # tests for both providers, and shellcheck
```

`docs/` is gitignored. It holds machine-local design notes and plans, and is
not part of the published marketplace.

## Provider Discovery

Claude and Codex use different marketplace roots and plugin manifests.

| Provider | Marketplace | Plugin Manifest |
|----------|-------------|-----------------|
| Claude | `.claude-plugin/marketplace.json` | `plugins/<name>/.claude-plugin/plugin.json` |
| Codex | `.agents/plugins/marketplace.json` | `codex/plugins/<name>/.codex-plugin/plugin.json` |

Codex does not read Claude plugin configuration as Codex plugins. When this repo is added as a Codex marketplace, Codex reads `.agents/plugins/marketplace.json`, then follows each entry's `source.path` to a Codex plugin directory. The current Codex marketplace points only to `./codex/plugins/<name>`.

Claude likewise reads the Claude marketplace and Claude manifests. It should not consume `.agents/plugins/marketplace.json` or `.codex-plugin/plugin.json`.

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
- Shared ideas can be documented in `docs/`, but runtime files should remain provider-local. `docs/` is gitignored, so those notes stay machine-local and are never published with the marketplace.
- Generated logs such as `firebase-debug.log` are ignored and should not be committed.
- Run `bash scripts/validate-release.sh` before publishing plugin updates, and
  `bash scripts/test-provider-parity.sh` when changing scheduler or context
  behavior on either side. CI runs both, plus every plugin's smoke tests and
  `shellcheck --severity=warning` over all `*.sh`, on push to `main` and on
  pull requests.
- `claude plugin validate <path>` checks a single plugin or marketplace manifest
  against the Claude schema, which is a faster inner-loop check than a full
  release validation.
- `session-scheduler` is intentionally a file-backed ledger layered on `session-chat`; keep scheduling state out of the transport plugin.
- `session-workspace` owns tmux session/pane lifecycle for adopting projects. Behavior belongs in the plugin engine; a project's root `workspace.sh` is a thin bootstrap shim with no project logic in it.
