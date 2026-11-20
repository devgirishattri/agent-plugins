# Claude and Codex Plugins

[![validate](https://github.com/devgirishattri/agent-plugins/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/devgirishattri/agent-plugins/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

This repository contains provider-specific plugins for Claude Code and Codex. The plugin implementations are intentionally separated by provider so each runtime reads only the configuration format it understands.

## Plugins

Every plugin below ships for both providers at the same version number.

| Plugin | Version | Purpose |
|--------|---------|---------|
| `session-manager` | 1.8.1 | List, search, and delete local sessions. Codex also supports archive and unarchive. |
| `session-chat` | 0.17.23 | Name tmux panes, send messages, and dispatch tasks between sessions |
| `session-scheduler` | 0.7.11 | Track and assign task ids across orchestrator, executor, and reviewer panes |
| `knowledge` | 0.5.14 | Unified taxonomy tooling for durable project knowledge: docs, memory, and context snapshots in one plugin. Adds a native memory store with consolidation, promotion, deterministic search/recall, a backlink graph, and a read-only cross-store doctor. Absorbs the retired `session-context` and `creating-docs` |
| `session-workspace` | 0.17.1 | Config-driven tmux workspace with strict-v1 role policy, reviewed Git orchestration, and peer orchestrators with on-demand workers |
| `chronos` | 0.1.5 | Inject fresh current date/time context with every prompt for time/day-aware agents |
| `session-walkthrough` | 0.3.1 | Walk users through session changes with a live in-browser overlay tour |

This table is the fifth place a plugin version is written down, after the two
plugin manifests and the two marketplace files. `scripts/validate-release.sh`
holds all five in agreement and fails the release when they drift, so bump the
version here along with the other four.

## Requirements

Supported platforms are macOS and Linux; `session-manager` also runs on Windows
under WSL. The scripts run on the bash 3.2 that macOS ships, which is verified
rather than assumed: the `session-scheduler` Claude suite passes 81/81 under 3.2.57.

| Dependency | Needed by | Hard or optional |
|------------|-----------|------------------|
| `jq` | `session-scheduler`, `session-workspace` | Hard. Both refuse to run without it. |
| `python3`, `git` | `session-scheduler` contracts | Required for contracted verification; legacy tasks retain existing dependencies. |
| `node`, `python3` | `session-walkthrough` tests | Required to run the plugin suite and the live tour overlay tests (`node:test`, no packages). The tour itself runs in the browser and needs neither. |
| `python3`, `gh` | `session-workspace` PR status | Python is required; live GitHub reads additionally require authenticated `gh`. |
| `python3`, `bash`, `tmux`, `jq`, `git`, `rg` | Scheduler verification pilot | Required by the source-checkout runner; not an installed helper. |
| `jq` | `chronos` | Optional. Claude falls back to hand-built JSON; the Codex build never uses jq. |
| `curl` | `session-workspace` browser integration | Required for DevTools readiness when starting a selected managed browser from `browser` or schema-v5 `browsers[]`. |
| `tmux` | `session-chat`, `session-workspace` | Hard. `session-chat` additionally requires that the agent itself be running inside a tmux pane, not merely that tmux be installed. |
| `tmux` | `session-scheduler` | Hard in practice. The ledger itself does not touch tmux, but every notify path goes through `session-chat`. |
| `tmux` | `knowledge` | Required for `context-share`, inside an active tmux session. Otherwise optional for pane identity, where `KNOWLEDGE_PANE_NAME` substitutes. |
| `git` | `knowledge` | Hard. Store resolution and `init` both require a repository. |
| `python3` | `knowledge` search and recall | Hard. `memory-search.sh` calls it unguarded, so `/knowledge:search`, `/knowledge:recall`, and auto-recall all need it. |
| `python3` | `knowledge` v2 handoffs | Required to save or regenerate structured scope/items. Legacy v1 and plain snapshot writes retain their existing behavior. |
| `python3` | `session-manager` on Codex | Required to read names from `session_index.jsonl` for listing, search, deletion selection, and statistics. |
| `python3` | `session-workspace` harness policy | Required when a schema 2–6 harness is active or the hook must validate a claimed reviewer identity. |
| `python3` | `knowledge` doctor, `session-chat` message surfacing | Optional. Both degrade rather than fail. |
| `codex` CLI | `session-manager` on Codex | Required for native deletion, archive and unarchive. Single-session delete, archive and unarchive exit 127 if the CLI is unavailable. Bulk deletion can return 1 when planning or deletion fails. |
| GNU or BSD `date` plus a zoneinfo tree | `chronos` | Hard. It validates `AGENT_PLUGINS_TIME_ZONE` against the system zoneinfo. |

Release validation uses Ruby. The source-checkout scheduler pilot also requires ripgrep. On Claude, `session-manager` and `chronos` need nothing beyond
bash and the system `date`.

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

Verify the installed version and that the intended skills, tools and hooks are
visible after upgrading. Start a new Codex session if the running session still
shows stale plugin content. Review changed hook trust separately; installation
does not grant trust. See [OpenAI's Codex plugin guide](https://learn.chatgpt.com/docs/plugins).
Check installed and enabled versions with:

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
run `/reload-plugins` in open Claude Code sessions to load the updated hooks,
commands, skills and MCP/LSP servers. If the new commands remain unavailable,
restart the session. Monitors require a full restart. This is the documented
[Claude reload behavior](https://code.claude.com/docs/en/plugins-reference);
verify the installed version after updating.

Reloading plugins does not change launch-inherited environment variables such
as `SESSION_CONTEXT_HOME` or `SESSION_SCHEDULER_HOME`. Relaunch the pane after
changing those variables.

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

Configure store paths in the launcher before starting the agent. Scheduler operations
require `SESSION_SCHEDULER_HOME`. Single-project context operations and tasks that
attach a named snapshot require `SESSION_CONTEXT_HOME`. The Codex context-search
skill also requires it. Claude’s cross-project search can discover stores without it.
`knowledge:doctor` can inspect `<repo-root>/.tmp/contexts` when the variable is unset.

```bash
export SESSION_CONTEXT_HOME="$HOME/.agent-context"     # knowledge context snapshots
export SESSION_SCHEDULER_HOME="$HOME/.agent-tasks"     # session-scheduler task ledger
```

The paths are yours to choose; only the variable names are fixed. Set them in
the shell that launches Claude Code or Codex, or in your shell profile. Scripts
that need them fail closed with an explicit error when they are unset rather
than guessing a path, so a missing export surfaces as a clear failure instead of
silent misbehavior.

In a workspace config, include `scheduler`, `contexts` or `messages` in
`stores.pin`. Set `pin_to_session: true` on each pane group that needs the
corresponding `SESSION_SCHEDULER_HOME`, `SESSION_CONTEXT_HOME` or
`SESSION_CHAT_TARGET_MESSAGES_DIR`. The default is false. The engine reserves
these variable names and rejects overrides in `env.groups`.

### session-manager

On Claude, deleting one session removes everything Claude Code keeps for it:
the transcript and any set-aside copies (`<session>.orphaned-*.jsonl`,
`<session>.jsonl.superseded-*`), subagent data, session env, debug log, file
history, legacy todos, the task list, `image-cache/`, `uploads/` and
`dev-mods/` entries, its `history.jsonl` lines, and the session's temp
directory (scratchpad, images and task output) and `cache-break-state-<session>.json`.
It checks each distinct `claude-<uid>` root under `CLAUDE_CODE_TMPDIR`,
`TMPDIR` and `/tmp` for these records. A target
reached through a symlinked directory is refused, and so is a temp root that is
a symlink or owned by another user.

It reads the session data your runtime already writes. On Codex, install
Python 3 to read session names. Deletion, archive and unarchive require the
native `codex` CLI on `PATH`. Native lookup tries an existing Codex daemon's
WebSocket control socket, then a temporary stdio app server that it closes after
lookup. No manual daemon startup is required; it never starts a persistent daemon.
If both native connections fail, auto mode reports a warning and falls back to local
session files and the latest names in `session_index.jsonl`; missing names display
`(untitled)`. Native metadata supplies names when available, and native-only
history has an unknown physical size until a local file is found.

Codex bulk deletion preflights native access before starting, then requires a
fresh native UUID-to-project match before each removal. Preview with
`scripts/delete-all-sessions.sh --plan [project-path]`: it separates eligible
sessions from skipped filesystem-only or conflicting records. Unavailable
native metadata or filesystem-only mode refuses the batch before deletion.
The result includes deleted, failed, and skipped counts, with UUIDs and specific
reasons for failures. Skips or failures make a confirmed batch exit nonzero.
Transcript fallback remains available for read-only listing; native deletion
continues through `codex delete --force`.

`SESSION_MANAGER_BACKEND=filesystem codex-ls` explicitly selects local files and
skips the native connection attempt (when using the shell alias). The same
environment setting applies to `scripts/list-sessions.sh` and
`scripts/session-stats.sh`; `auto` is the default and `native` fails instead of
falling back. The isolated real-daemon regression can be run with
`python3 -B scripts/test-session-metadata-live.py`; CI pins Codex CLI 0.169.0,
uses synthetic histories, makes no model calls, and stops its disposable daemon.
`python3 -B scripts/test-session-deletion-live.py` verifies preview and native
deletion without a daemon in an isolated home, including preservation of another
project's history. The temporary-connection deletion path is verified on 0.169.0.

Codex also gets `session-archive` and `session-unarchive` (1.8.0), which have no
Claude Code counterpart. Archiving is the reversible step before a delete: the
native `codex archive` moves the session to `archived_sessions/` and out of the
active list, and `codex unarchive` brings it back. `scripts/prepare-archive.sh
archive|unarchive [target]` resolves the target read-only, among active sessions
for archive and archived ones for unarchive, and `scripts/archive-session.sh`
passes only a full UUID to the native command. `list-sessions.sh --archived-only`
lists archived sessions. `python3 -B scripts/test-session-archive-live.py` runs the
round trip without a daemon in an isolated home.

### session-walkthrough

A walkthrough request ("walk me through the change", "show me the changes",
`/session-walkthrough`) runs a live tour. The orchestrating agent injects
`scripts/tour/overlay.js` and a tour definition into the already-running
managed browser through chrome-devtools `evaluate_script`. Each step highlights
a new or changed element and quotes the request line it covers, or labels a
design decision. Steps can change control values. The user performs any save.
Close removes the tour overlay, listeners and saved tour state. Preserve user edits if an `onClose` callback undoes a value the tour itself set. See the
[live tour reference](plugins/session-walkthrough/skills/session-walkthrough/references/live-tour.md)
and the walkable [example](plugins/session-walkthrough/examples/live-tour/README.md),
a synthetic demo page with a nine-step tour.

The plugin makes no recordings: no screenshots, clips, manifests or report
pages. It has no settings, registers no hooks and uploads nothing. See the
[walkthrough skill](plugins/session-walkthrough/skills/session-walkthrough/SKILL.md)
for the procedure and authority boundaries.

### chronos

No setup. Its hooks inject the current time once the plugin is enabled. Set
`AGENT_PLUGINS_TIME_ZONE` to a valid IANA zone to change from the `Asia/Kolkata`
default.

### knowledge

Knowledge 0.5.0 adds `distill`: say “wrap up this session” or invoke
`/knowledge:distill` (Codex: `$knowledge:distill`) to prepare relevant docs,
memory, configured tickets and context as one concrete batch. After approval,
it applies the changes through existing writers and saves context last with
actual outcomes. It does not ask you to invoke each writer separately.
`reflect` remains the write-free current-task alternative.

Distill uses existing, configured tracker tools; it does not ship a Jira client
or configure credentials. Missing tracker access yields drafts. It avoids
duplicate posts after ambiguous results, leaves unrelated candidates pending,
and excludes deletion, promotion and status transitions. One batch is capped
at 10 mutations / 30,000 UTF-8 bytes of proposed diffs/payloads; larger work is
reviewed in separate batches. Approval is of exact content, not skill selection
or a tool-permission prompt. Document pre-write checks are not atomic CAS.

`remember` can now capture a verified lesson or preference implicitly into
the inbox, with evidence and writer-assigned session/pane provenance.
`recall` can perform bounded targeted lookups when a new topic emerges.
Implicit selection is best effort, not a guarantee on every task. Durable
memory promotion remains reviewed. Under strict-v1, capture needs
session-workspace 0.11.1 or later; old harnesses refuse the new helper path.

The memory store is per repository and must be created once, from inside the
repository:

```
/knowledge:init
```

That runs a plan/apply pair: it proposes the `.gitignore` line covering the
store, then creates `.agents/memory/` with an empty `MEMORY.md` at `0700`/`0600`.
It refuses to run outside a git repository, and re-running it is a no-op. Until
a store exists, the search, recall, and remember surfaces have nothing to read.

Documentation and context commands work without a memory store. Configure
`SESSION_CONTEXT_HOME` for work on individual snapshots.

Prompt-hook recall remains **off** on a fresh plugin install:
`KNOWLEDGE_AUTO_RECALL=1` enables session-start and prompt injection;
`session` or `prompt` selects one. `KNOWLEDGE_AUTO_RECALL_GRAPH=1`
additionally enables selective outgoing-link expansion. A launcher or workspace
configuration may set `KNOWLEDGE_AUTO_RECALL` for its sessions.

Implicit `remember` and `recall` skill selection is available without a
hook or repeated user commands. Automatic capture uses
`memory-auto-capture.sh`, requires evidence, and stays inbox-only. The
retired `KNOWLEDGE_AUTO_CAPTURE` variable governs nothing. Claude's optional
prompt Stop-hook snippet at `plugins/knowledge/assets/capture-stop-hook.md`
is an additional capture trigger; Codex skips prompt/agent handlers. Neither
provider should run a full Distill pass on every Stop.

Capture format compatibility: 0.5 reads older inbox candidates unchanged; new
captures add writer-assigned origin fields and may include evidence. Older
versions reject those fields. Before downgrading, review/consume pending new-format
candidates on 0.5 or retain a private backup and keep the 0.5 writer available;
do not edit candidate envelopes to fake compatibility (their IDs bind content).
Retained new-format dismissals also require 0.5 to inspect/restore. No inbox or
archive is deleted by a downgrade. Updating/restarting installed plugins is
required for runtime activation; changed hooks still require trust review.

`plugins/knowledge/assets/recall-snippet.md` holds a short instruction block you
can paste into `CLAUDE.md` or `AGENTS.md` so agents query the store before
substantive work.

### session-chat

The agent must be running **inside** a tmux pane; having tmux installed is not
enough, and the scripts exit with an error when `TMUX` is unset. Both ends of a
conversation need names, since names are the addresses: an unnamed sender is
refused, and an unnamed recipient cannot be resolved.

A `SessionStart` hook names a pane automatically from the session's custom
title, but only when the pane has no name yet. Set or change one explicitly with:

```
/whoami <name>
```

Delivery behavior on the receiving side is
controlled by `SESSION_CHAT_INCOMING_MODE`, which defaults to `notify`;
orchestration setups normally want `auto` or `assist`. All panes that need to
exchange messages must agree on one mailbox root, so if you override
`SESSION_CHAT_TARGET_MESSAGES_DIR`, export the same absolute path in every pane
before its agent starts.

New message IDs contain 16 lowercase hexadecimal characters from OS randomness.
Existing 8–16 character IDs remain readable. Failed randomness aborts sending.
The leading body envelope contains optional `[re:<id>]` then optional
`[task:<task-id>]`; later quoted tokens remain body text. Use `--task` on the
send or dispatch helper to add task association. `check-replies.sh --task ID`
shows matching associations, including multiple task replies to one request.
New replies are verified against the request's sender and recipient; legacy
rows without recipient context remain explicitly unknown. Correlation does not
establish task completion. Live hook JSON needs Python or jq to decode its
`prompt`; without either, live correlation is unavailable.

### session-scheduler

Needs `jq`, `SESSION_SCHEDULER_HOME`, and a working `session-chat` at **0.13.0
or newer**, which it enforces at runtime and which exists so a dispatch to a
busy pane is recovered from the durable inbox instead of lost. It layers a
file-backed ledger on that transport, so set up `session-chat` first and confirm
panes can actually message each other before assigning tasks.

Scheduler 0.7.5 accepts a complete reviewer verdict through
`task-done <id> --note-file <own draft>` or `task-block` with the same operands.
Contracted tasks also require `--generation <N>`. This option requires chat
0.17.18 and workspace 0.11.5 for the matching strict-v1 grammar. Install the
three versions together on both providers. Missing draft-validation support
refuses this option before reading the file; legacy inline notes remain usable.
The transition and verdict event commit together, then one normal-path
notification carries the complete verdict to the assigner. Task status shows
the saved artifact and delivery outcome; `pending` means unconfirmed. Do not
rerun a transition to repair notification, or send a duplicate correlated
reply. An unchanged own draft is consumed after commit unless
`SESSION_CHAT_KEEP_DRAFTS=1`. Delivery does not prove recipient observation.

The ledger itself does not touch tmux, so creating and querying tasks works
outside it. Legacy assigning, reviewing, completing, and blocking notify through
`session-chat`, which does require tmux. Attaching an explicit knowledge
context (`--context NAME`) additionally requires `SESSION_CONTEXT_HOME`;
`--context auto` writes a scheduler-owned handoff under the ledger home and
needs nothing else.

Run `/scheduler-doctor` first. It checks jq, tmux, the session-chat install and
its version, ledger-home drift, and the current pane's incoming mode, and it
warns when an executor sits in the default `notify` mode, where it will not act
on dispatched tasks.

Scheduler 0.7.0 adds opt-in `task-contract` verification. Attach existing tracked
checks to a new task with a distinct reviewer, show the check list, and verify
with its exact spec digest. Assignments carry generations and bounded attempts;
completion requires source-bound executed evidence and independent reviewer
admission. Dependencies use durable admission; `inspect --fresh` and
`inspect --committed` add current-source checks for commit and release preflight.
Reconcile ambiguous outcomes explicitly before reassignment. No automatic retry
or force flag bypasses the contract. Contracted done/block with inline notes
write the ledger. With `--note-file`, they also record the verdict and attempt
to notify the eligible assigner. The coordinator can read task status.
Receipts stay in the scheduler handoff directory. Cleanup retains contracted tasks. All participating panes
and consumers need scheduler 0.7.0. Verification needs Python 3 and Git, runs
with an isolated environment, and preserves the active harness policy. Local
digests do not authenticate an external runner or authorize a release.

New scheduler IDs use `task-<epoch>-<8hex>` from OS randomness. Existing task
IDs remain valid. Creation refuses collisions among cooperating scheduler
writers under the shared task lock, then atomically publishes complete JSON.
Codex task cleanup can delete a surviving task’s base prompt when its ID overlaps
another task’s review or acknowledgement filename. See the cleanup skill before
applying a batch with overlapping IDs. [Codex task cleanup](codex/plugins/session-scheduler/skills/tasks-clean/SKILL.md)

Ordinary done/block/review failures report `DIAG` JSON with separate transition,
notification and bookkeeping observations. Workspace hook denials report the
same schema. Each plugin ships its reason registry in `diagnostics/registry.json`.
These lines are unauthenticated: echoed input can resemble a diagnostic, and
missing output does not prove success. Inspect task status before retrying an
uncertain transition. Contract-engine and other helper diagnostics remain deferred.

### session-workspace

Version 0.11.7 permits quoted literal paths such as `src/app/[id]/page.tsx`
while retaining containment and symlink checks. For supported Git pathspec
commands, use `git --literal-pathspecs <command> -- '<path>'`; the new permission
allows no other global option except `-C .`. Task notes and chat message bodies
can mention plugin cache paths. File operands keep their existing restrictions.
See the session-workspace skill for the supported Git forms and limitations.

For permission setup and proposed verifier execution, read the provider's
session-workspace skill and its
[owner-reviewed verifier guidance](plugins/session-workspace/skills/session-workspace/references/verifier-capability.md).
These documents add no execution grants or sandbox exceptions.

Since 0.11.1, strict-v1 permits `memory-auto-capture.sh [--store P] --staged FILE...`
for orchestrators and executors. Reviewers are denied, and `--batch-dir` is refused.

Version 0.11.0 adds `verification-recipe` and `blast-radius` skills. The first
creates or maintains a project-local recipe with real behavior checks, isolated
fixtures, retained evidence, and explicit coverage limits. The second reviews
indirect consumers and tests the assumptions that make a change safe. Both use
existing role and authorization boundaries; neither creates an approval ledger
or changes the workspace schema. `adversarial-review` adds bounded independent
critique with explicit finding dispositions; `benchmark-check` checks correctness,
comparable repeated measurements, and end-to-end effects. `behavioral-eval`
grades observable actions and artifacts, with model runs still requiring an
explicit spending ceiling. `pr-status` performs one structured, read-only GitHub
check for CI, review, thread and merge blockers; unknown data never becomes ready.

In this source checkout, run the isolated scheduler pilot with
`python3 -B scripts/verify-scheduler-workflow.py run --provider codex --output .tmp/verification/codex-run-1`
(or `--provider claude` with a new output path). Use `check --output <same-path>`
to compare a recorded pass with current source and artifact hashes. Evidence
survives fixture cleanup. This root helper is not installed with the plugin;
its local consistency checks do not authenticate execution or authorize release.

Needs tmux and `jq`. Setup is once per machine, then once per project.

Per machine, put the dispatcher on `PATH`:

```
/workspace-install
```

That copies the plugin's `templates/workspace-dispatcher.sh` to
`~/.local/bin/workspace` (override with `--target`). It is idempotent and is
also how you refresh the copy after a plugin update, which matters because the
dispatcher lives outside the versioned plugin cache and can otherwise go stale.

Create `.agent-workspace/workspace.json` in the repository root. It describes
sessions, panes, model grants, coordination stores and secrets. The installed
`workspace` command discovers this config from the current project. To support
callers that invoke `./workspace.sh`, use the optional `templates/workspace.sh`
shim. Keep project-specific behavior in the JSON config.

### Secret visibility by role

Session-workspace 0.8.0 supports per-key recipients in every supported
`schema_version`. The global role list remains an access ceiling:

| Setting | Meaning |
|---|---|
| `secrets.allow` string entry | Key is available to every globally visible role. |
| `secrets.allow` object entry | Required `key` and `roles`; key is available only to roles in both its list and the global list. Unknown fields are rejected. |
| `secrets.visible_to_roles` | Configured role names; omitted/empty means no grants. Known per-key roles outside this ceiling receive nothing. |
| `secrets.on_missing` | `warn` (default) or `fail`, applied only after filtering to keys the receiving role may see. |
| `secrets.env_file` | Optional value source; when configured it must pass the existing owner-only, mode-0600, non-symlink, project-contained, git-ignore gates. Nonempty caller environment values still take precedence. |

For example, with `master`, `executor`, and `reviewer` declared in `roles`:

```json
{
  "secrets": {
    "env_file": ".agent-workspace/secrets.env",
    "visible_to_roles": ["master", "executor", "reviewer"],
    "allow": [
      {"key": "GH_TOKEN", "roles": ["executor", "reviewer"]},
      {"key": "SECOND_READ_TOKEN", "roles": ["executor", "reviewer"]},
      {"key": "GITHUB_MCP_TOKEN", "roles": ["master"]}
    ],
    "on_missing": "fail"
  }
}
```

Master receives only `GITHUB_MCP_TOKEN`; executor and reviewer receive the
other two keys. A missing master token cannot warn or block executor delivery.
Empty per-key `roles` grants nothing. Unknown roles, duplicate per-key roles,
duplicate keys across either form (exact case-sensitive matches), invalid key
names, and missing/null object fields are validation errors. Keys must match
`^[A-Za-z_][A-Za-z0-9_]*$`. Both adapter paths use the same authorization rule;
single-key denial errors identify the rule without revealing value presence.

Plan shows `secret_keys_by_role` and per-pane `secret_keys`; doctor shows
effective key names by role and keys with no recipient. Neither prints values.
Doctor remains a workspace-wide file diagnostic: object/mixed configs check
only keys with an effective recipient and name affected roles; string-only
configs retain the legacy scan of all listed keys. File diagnostics do not
resolve caller-environment overrides. The explicit authorized `secret-value`
lookup returns a value on stdout and must not be used for reporting.

Delivery still uses private single-use 0600 files and never mirrors secrets
into the tmux session environment. This controls workspace delivery, not
same-user file access or credentials inherited through other mechanisms.

**Migration and rollback:** existing unique-key string-only configs need no
change. Upgrade both providers before adopting objects. Convert restricted
string entries to objects in the same edit that expands global visibility;
otherwise those strings intentionally grant access to the newly listed role.
Inspect plan/doctor and restart affected panes and MCP processes. No schema
version or store migration is required. Before downgrading, restore a safely
restricted legacy config; do not flatten objects to strings under a widened
global list. Previously delivered credentials remain in running processes
until those processes restart. Duplicate key rejection tightens old validation.

### Coordination directories

Create the coordination directories yourself. The engine deliberately does not:
for ordinary pane/session lifecycle it creates only its own state directory and
the tmux lock directory. A configured browser is the exception: browser startup
also creates its derived Chrome profile directory. On a fresh clone the
`messages`, `scheduler`, and `contexts` directories under `stores.base` (and the
memory root) must already exist or the first agent to write to one can fail.

```bash
mkdir -p "$STORES_BASE"/{messages,scheduler,contexts}
chmod 700 "$STORES_BASE"/{messages,scheduler,contexts}
```

#### Message store access

With session-workspace 0.10.0 and session-chat 0.17.13, executors and reviewers
can read complete file dispatches using one literal command such as
`cat '<absolute-message-path>'`. The incoming hook prints that command before
the inline body, so the complete task remains available when either the
`SESSION_CHAT_DISPATCH_INLINE_MAX` limit or the total hook-context limit is hit.
The inline limit is a display tunable, not a task-size limit. Incoming
`notify`/`assist` consent rules still apply.

The trusted dispatch helper saves the complete transport copy directly in the
validated messages grant as `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md`.
This is normally `<workspace>/.tmp/messages`; configured store overrides remain
supported. Editable drafts stay in `drafts/<own-pane>/` beneath that root.
The policy takes roots and pane identity from the validated plan, never from
an inherited store or pane-name override. Sending still follows the existing
coordinator routes; this read grant does not enable peer-to-peer sends.

Child shell reads allow only existing own drafts or private, single-link,
regular delivered files sent by or addressed to that pane. Both endpoints must
form exactly one valid pair in the current plan, including when names contain
`-to-`. Historical files involving removed panes or ambiguous pairs fail closed.
Traversal, symlink components, other panes' messages/drafts, subdirectories,
queue/archive/ledger state, and ungranted provider inboxes are denied. Reviewers
previously had broader message-store reads; 0.10.0 deliberately narrows them.
The existing read grammar applies: no pipes, redirection, expansion, globs,
`sed`, or symlink-follow options. Own-draft writes and coordinator access are
unchanged; delivered files are written by trusted helpers.
The restricted read grammar rejects NUL-separated filename-list options in
`sort`, `du`, `wc`, and `find`, including long-option abbreviations. File contents
cannot supply unchecked read operands. Ordinary executor in-checkout shell
commands retain their existing floor; this is not general process isolation.
Git operands do not receive this message-read exception.

Recursive reads that could enter the store are also denied, including `rg`,
`find`, `du`, recursive `grep`, and `ls -R` from an ancestor directory. Name
explicit safe subdirectories; glob exclusions do not grant an exception.
Child shell workdirs cannot be inside the store. These are shell-operand
guardrails, not filesystem isolation: Claude native `Read` remains ungated,
and arbitrary executable internals and concurrent same-user filesystem swaps
are not covered. Update both plugins and restart affected panes; there is no
schema or store migration. Rollback restores the executor read failure and
the broader reviewer access.

Under strict-v1 (workspace 0.7.1), reviewers, executors, and confined coordinators
with a validated `messages` grant may use native edit tools to create, revise,
and delete their own `.md`/`.txt` drafts at
`<messages-grant>/drafts/<pane-name>/<safe-name>.md`. Use a fresh filename whose
stem starts with an ASCII letter/digit, contains only ASCII letters/digits,
`.`, `_`, or `-`, and is at most 128 characters. Resolve the grant and identity
from the validated workspace plan; inherited variables cannot grant access.
Use the installed dispatch helper with `--reply-to` for replies. It creates a
separate transport copy. After a delivered, durable queued, or unsubmitted
result (exit 4, whose durable copy stays queued), session-chat consumes eligible
unchanged own-pane drafts unless `SESSION_CHAT_KEEP_DRAFTS=1`.
Failed reads and hard transport failures retain the source. Changed or ineligible
files remain intact. Do not delete a retained draft or resend a successful
packet because cleanup kept its source.
Shell staging/cleanup, transport-message edits, peer drafts, queue/archive/ledger
state, symlinks, hardlinks, moves, and mixed draft/product patches remain blocked.
No grant means no staging exception. Existing reviewer top-level drafts must be
restaged in the new namespace; never move transport files. Update session-chat
and session-workspace, then restart affected agents; no config/schema change is
required. Downgrading restores the executor staging failure and reviewer
transport-edit flaw. The root coordinator retains authority to edit the entire store, including
transport messages. Confined coordinators must use native reads or trusted
helpers to read the message store; arbitrary shell access is blocked even when
the store is nested inside their checkout.

A group with `pin_to_session: true` receives the coordination variables selected
by `stores.pin`. To make panes write to
that memory root, restate the same path as `KNOWLEDGE_MEMORY_HOME` in an
`env.groups` block. Nothing keeps the two in sync, so changing one alone makes
them diverge silently.

Then check the config and preview the plan before touching tmux. Both are
read-only:

```
/workspace-doctor
/workspace-plan
```

`/workspace-start` creates missing workspace resources. `/workspace-stop` and
adopting unmanaged panes require explicit confirmation. With the default stop
scope, `workspace stop --confirmed` selects every configured session. Supply a
session ID to select one. `--all` or `behavior.stop_scope: all` widens the stop
to every session marked for this project. `/workspace-restart` passes confirmation
to its own stop phase. With `behavior.stop_scope: all`, a targeted restart can stop other project-marked sessions and start only the named one.
See the [workspace configuration](plugins/session-workspace/README.md).

Schemas 4–6 support the `workspace-orchestrator` skill and its fixed
`reviewed-git-v1` lifecycle. The orchestrator assigns work, the executor implements
it and performs authorized Git operations, and the reviewer records the audit.
Commit, push and deploy have separate gates. For ordinary targets the executor
merges into the release branch after separate user confirmation. A v5 executor
bound to one branch may commit and push that work branch. For those lanes,
the separately authorized release merge runs in the main checkout.

Since session-workspace 0.9.0, strict-v1 classifies remote-mutating `gh` commands by
root and confined orchestrators even without a child-checkout operand. Audit mode
warns and enforce mode blocks. Route authorized mutations through the executor. Reviewed
single-command reads remain available: `run list/view`, `pr list/view/diff/checks`,
`workflow list/view`, `release list/view` with `--repo`/`-R OWNER/NAME`,
`repo view OWNER/NAME`, and `api repos/OWNER/NAME/...` or
`api repositories/ID/...` with effective GET. No owner allowlist is applied.

Use `--json`, `--jq` and supported `--limit` flags instead of pipelines. Aliases,
extensions, unknown commands/options, path-valued repository selectors, browser
launches, wrappers, inline environment assignments, expansions, redirections and
composed shell commands are outside the allowance. Supply credentials through
the existing launch-inherited secret contract, not inline assignments. API
fields and `--input` require explicit uppercase `--method GET` or `-X GET`;
otherwise they imply POST and are denied. File-backed fields and input still
transmit file contents to GitHub even on GET, and confined orchestrators retain
filesystem containment for those paths. Stdin inputs, command-line host
overrides (`://` endpoints and `--hostname`), request headers and explicit API
caching are unsupported. Inherited `GH_HOST` and gh configuration remain trusted
launch environment; this does not guarantee a fixed destination host. A literal
`gh` operand to a non-data command (for example `git log --author gh`) is also
refused conservatively.

The reviewed grammar is based on `gh` 2.100.0; unreviewed future options fail
closed. Executor containment and reviewer command permissions are unchanged;
delivering `GH_TOKEN` does not authorize reviewer `gh` calls. No configuration or
store migration is needed. Update both provider plugins and restart affected
agents; accept Codex hook trust when prompted. Downgrading restores the remote
mutation gap and previous read restrictions. This is an argv guardrail for root
and confined orchestrators, not subprocess isolation: script files and
interpreters fed on stdin (and, for root, inline interpreter code) can still
invoke gh. Where remote mutations must be impossible, withhold write-scoped
GitHub credentials from orchestrators using per-role secret visibility.
Unclassified MCP calls retain their existing limits. Git stderr-redirection and
loop handling are unchanged.

### Hooks and restarts

`chronos`, `knowledge`, and `session-chat` register lifecycle hooks;
`session-manager`, `session-scheduler`, and `session-walkthrough` register none. `session-workspace`
registers opt-in harness hooks for schemas v2–v5. An ordinary unbound pane
runs with the harness inactive. A pane launched with an active harness fails
closed when its validated mode, identity, read grants, guards or own environment scope drift. A pane claiming a reviewer identity also
requires a readable workspace config before the hook can establish its mode.
`knowledge` and `session-chat` use `SessionStart`, `UserPromptSubmit`, and
`Stop` on both providers. `chronos` differs by provider: Claude registers
`UserPromptSubmit` plus a throttled `PostToolBatch` refresh, while Codex registers
only `UserPromptSubmit`, so `CHRONOS_INTERVAL_MIN` has no effect there.

Registering a hook is not the same as turning a feature on. `knowledge`'s
automatic recall and Stop nudge are opt-in. Its SessionStart snapshot detector
remains automatic, but is silent when the project has no saved snapshots.

Codex prompts for trust before running a plugin's hooks, and installing or
enabling a plugin does not grant that trust on its own. Restart the session
after installing or updating a plugin so the runtime loads the new code and
hooks.

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
| `SESSION_CHAT_SUBMIT_VERIFY_MS` | `1000` | After Enter, how long to wait for the recipient's input line to clear. If the text is still staged, one extra Enter follows and is checked for the same window; still staged means exit 4 (unsubmitted) with the durable copy queued. `0` turns the check off. |
| `SESSION_CHAT_SUBMIT_RETRY_DELAY_MS` | `250` | Pause before that single extra Enter, so a paste burst in the recipient's TUI can end first. |
| `SESSION_CHAT_SEND_MAX_LEN` | `1024` | Maximum single-line payload length for `send`; use `dispatch` for larger or multiline content. |
| `SESSION_CHAT_SEND_RETRIES` | `2` | Retries after live marker-verification timeouts; total attempts are retries plus one. |
| `SESSION_CHAT_RETRY_BACKOFF_MS` | `200` | Linear retry-backoff base in milliseconds. |
| `SESSION_CHAT_LOCK_TIMEOUT_MS` | Derived | Per-target send-lock wait budget. When unset, it is derived from the send budget and resets when the lock holder changes; an explicitly configured value is a hard cap. |
| `SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS` | Derived | Delay before a recipient may surface a pre-live durable queue row. The default is the lock budget plus one send budget plus 1000 ms. |
| `SESSION_CHAT_RECENT_ID_TTL_MS` | `600000` | How long surfaced message IDs suppress duplicate live and queued arrivals. |
| `SESSION_CHAT_DISPATCH_INLINE_MAX` | `6000` | Maximum trusted dispatch-body characters inlined in `auto` mode. |
| `SESSION_CHAT_ARCHIVE_RETENTION_DAYS` | `30` | Retention for daily searchable message-archive files. |
| `SESSION_CHAT_KEEP_DRAFTS` | `0` | Set to `1` to retain eligible own-pane drafts after durable dispatch. Otherwise, the transport checks source identity and SHA-256 before removing them. Other prompt files are retained. |
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
| `SESSION_CHAT_REPLY_SCAN_BYTES` | Both | `4096` | Maximum prefix read from a trusted dispatch file for its leading reply envelope. An undecided envelope at the limit records no correlation. |

`HOME` supplies the standard fallback roots, and `TMPDIR` selects the parent
for private temporary and send-lock directories. The runtime supplies `TMUX`,
`TMUX_PANE`, and the provider plugin-root variables; these are integration
inputs, not session-chat user settings.

## Other Plugin Configuration

The remaining plugins expose the variables below. A `Yes` in both provider
columns means both implementations read the variable for the stated purpose;
provider-specific differences are called out explicitly.

### Knowledge (context snapshots)

`knowledge:find` searches the current repository’s README/docs, resolved memory
store, and inherited context store together. Results stay grouped by source with
authority and lifetime labels; memory retains its native ranking and any degraded
query notice. The read-only command supports source selection, per-source limits,
and JSON output, reports partial/unavailable sources, and caps output at 64 KiB.
See the command contracts for [Claude](plugins/knowledge/skills/find/SKILL.md) and
[Codex](codex/plugins/knowledge/skills/find/SKILL.md).

Structured v2 handoffs record repository scope, stable work-item IDs, reported
status, and evidence references. The context-generation workflow stages a JSON
data file for `save-context.sh --handoff --handoff-data <file>`; direct legacy
calls without data still produce v1. Doctor checks the structure, timestamp consistency, expired open work, and
recorded evidence age. Explicit `reference` evidence of the form `memory:<slug>`
also lets doctor flag missing, stale, superseded, or archived memory entries in the resolved memory
store. These are review cues; evidence remains unverified. `context-verify <name> --repository-id <id>`
checks local paths and commit ancestry against an explicitly bound repository;
recorded test results and external references remain unverified. See the handoff contracts for
[Claude](plugins/knowledge/skills/knowledge/references/handoffs.md) and
[Codex](codex/plugins/knowledge/skills/knowledge/references/handoffs.md).

These variables keep the `SESSION_CONTEXT_*` names they had under the retired
`session-context` plugin, but they are now read by `knowledge`.

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `SESSION_CONTEXT_HOME` | Yes | Yes | Inherited for single-project commands and the Codex search skill | Snapshot store root. Both cross-project search helpers can discover stores without it. When set, it overrides the current project's search store. Claude's search command uses that discovery directly. The SessionStart banner can initialize, lock and harden a git-root fallback store. |
| `SESSION_CONTEXT_STALE_DAYS` | Yes | Yes | `7` | Age at which `context-load` warns that a snapshot is stale. Doctor also uses it for file age and newest evidence age on in-progress/blocked handoff items; doctor accepts 0-999999 and warns/falls back to 7 for invalid values. |
| `SESSION_CHAT_ROOT_OVERRIDE` | Yes | Yes | Unset | Development/integration override for locating the `session-chat` dependency used by `context-share`. |
| `SESSION_CHAT_PLUGIN_ROOT` | No | Yes | Unset | Additional Codex-only explicit locator for the `session-chat` dependency. |

Cross-project search reads existing stores without creating directories or changing their permissions.
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
| `SESSION_CONTEXT_HOME` | Yes | Yes | Required for explicit context (inherited) | Resolves an explicit `--context NAME` snapshot. `--context auto` uses scheduler-owned handoffs and does not require this variable. |
| `SESSION_SCHEDULER_STALE_MINUTES` | Yes | Yes | `30` | Age after which assigned or review tasks are marked `STALE`. |
| `SESSION_SCHEDULER_NOTE_MAX_BYTES` | Yes | Yes | `65536` | Maximum bytes for an own-draft verdict passed with `--note-file`; size is checked before hashing, then raw UTF-8 and NUL validation runs. |
| `SESSION_SCHEDULER_FORCE` | Yes | Yes | `0` | Set to `1` to permit otherwise illegal legacy status transitions. Prefer `--force`. Contracted tasks refuse both overrides. |
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
`task-block`) perform nested session-chat/tmux transport for legacy tasks.
Contracted assignment and review also use transport. Contracted done and block use it to notify an eligible assigner when called with `--note-file`. Inline notes update the ledger only. A
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
| `SESSION_WORKSPACE_SOURCE_TREE_DIR` | Yes | Yes | Unset | Development override for finding sibling dependency plugins in a source checkout. |
| `SESSION_WORKSPACE_TMUX_SOCKET` | Yes | Yes | Derived at entry | Absolute tmux socket path for a workspace operation and its children. Inside tmux it must match the socket in `TMUX`. Outside tmux the default is `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`. Set it explicitly to select a private test server. |
| `SESSION_WORKSPACE_LOCK_TIMEOUT` | Yes | Yes | `30` | Seconds to wait for the tmux lifecycle lock before giving up. |
| `SESSION_WORKSPACE_AGENT_READY_TIMEOUT` | Yes | Yes | `120` | Total seconds to wait for each targeted worker pane to become ready, including its settle window. |
| `SESSION_WORKSPACE_AGENT_READY_SETTLE_MS` | Yes | Yes | `1500` | Settle window in milliseconds for a worker's input line. A menu or missing input line restarts the window. Set to `0` to accept the first input line. |
| `SESSION_WORKSPACE_HIDDEN_SIZE` | Yes | Yes | `160x48` | Size for a hidden peer worker's tmux window, in `COLSxROWS`. Minimum 40 columns and 10 rows. Read when starting or hiding a worker. |
| `XDG_STATE_HOME` | Yes | Yes | `$HOME/.local/state` | With schema 6 peers, the engine exports the resolved state home to each pane. The engine and hook use the same `session-workspace/<project.id>/instances.json`. Configure the state home in the launcher. |
| `SESSION_WORKSPACE_STOP_GRACE_SECONDS` | Yes | Yes | `5` | Grace period given to a pane's agent to exit before `workspace-stop` escalates. |
| `SESSION_WORKSPACE_IDLE_OBSERVE` | Yes | Yes | Unset | Set to `connections` to make the browser's idle watcher count client connections instead of CDP traffic. Read when `start` arms the watcher. |
| `SESSION_WORKSPACE_IDLE_SAMPLE_SECONDS` | Yes | Yes | `30` | Seconds between idle-watcher samples, at most the idle window. Read when `start` arms the watcher. |
| `SESSION_WORKSPACE_IDLE_SECONDS_PER_MINUTE` | Yes | Yes | `60` | Length in seconds of one `idle_stop_minutes` minute. Intended for tests. |
| `SESSION_WORKSPACE_STOP_REASON` | Yes | Yes | Unset | Reason recorded for a `stop --pane`. The idle watcher sets it; leave it unset. |
| `SESSION_WORKSPACE_ATTACH_DRY_RUN` | Yes | Yes | `0` | Set to `1` to skip the terminal attach step. Intended for tests and automation. |

All behavior lives in the plugin engine. An adopting project contributes only a
versioned `.agent-workspace/workspace.json`. An optional `workspace.sh` shim
resolves the two locator variables and starts the engine. Lifecycle verbs are exposed as Claude commands (`/workspace-start`,
`/workspace-stop`, `/workspace-restart`, `/workspace-reconcile`,
`/workspace-status`, `/workspace-plan`, `/workspace-doctor`,
`/workspace-install`) and as matching Codex skills. `plan` and `doctor` mutate
nothing. `stop` and adoption require explicit confirmation; `restart` is the
destructive exception that confirms its internal stop phase itself and exposes
no separate `--confirmed` flag. Secrets declared in the config are handed to
panes as a private `0600` temp file passed by path, never through `send-keys` or
tmux metadata. See `plugins/session-workspace/README.md` for the config schema.

Strict-v1 reviewers and executors can keep a child checkout as `cwd` while granting selected
shell reads through per-pane `read_paths`, for example `["docs", "AGENTS.md"]`.
Executor grants permit only single literal read commands under the reviewer
read-command restrictions; executor workdirs and writes stay inside their own
checkout. For example, use `cat ../docs/guide.md` from the child checkout.
From session-workspace 0.7.1, executors also get restricted single-command reads
of selected installed `girishattri-plugins` versions without `read_paths`. This covers skills,
commands, references, and scripts as data, using separate `cat <absolute-path>`
calls, for example. It adds no cache writes, cache workdirs, execution privileges,
or store/inbox access; stale versions and unselected plugins remain outside scope.
Confined orchestrator behavior is unchanged. No configuration or store migration
is needed. Update the installed plugin and restart affected agents; downgrading
restores the earlier executor cache-read restriction.
Restricted ripgrep reads must start with `rg --no-config`, for example
`rg --no-config pattern ../docs`, so inherited configuration cannot enable
symlink traversal or preprocessors. Explicit follow/preprocessor options,
`--hostname-bin` and `-z`/`--search-zip` are forbidden. This applies to all
reviewer ripgrep reads and executor reads using grants outside their checkout;
ordinary executor in-checkout shell behavior is unchanged. Update existing
restricted-read commands when moving to 0.6.4; no config/store migration is needed.
Relative entries resolve against the workspace root; canonical absolute paths
can name external repositories. Existing files grant exact-file access and
directories grant descendants. These grants never become `--add-dir`, write
permissions, or knowledge-store grants, and do not change native-tool permissions.
Configured stores, memory, secrets, provider homes, foreign v5 environments,
symlink components, parent traversal, and overlapping grants are rejected.
The engine pins `SESSION_WORKSPACE_READ_PATHS_JSON` at launch; do not set it
manually. After adding/changing/removing paths, restart the affected workspace
session. Before downgrading below 0.6.3, remove executor `read_paths`; before
downgrading below 0.6.2, remove reviewer `read_paths` too. Restart affected sessions.
Native provider restrictions still apply; hooks cannot prevent a same-uid filesystem swap racing a check.
If a path disappears or becomes unsafe, plan/status show it as unavailable and
only its configured pane blocks; other panes and stop remain usable. Restore the path,
or change the configuration and restart. Launch refuses unavailable grants.

### Chronos

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `CHRONOS_INTERVAL_MIN` | Yes | No | `5` | Throttle window in minutes for the Claude-only PostToolBatch refresh hook. Within the window, PostToolBatch emits nothing; UserPromptSubmit always injects a fresh timestamp regardless. |

Chronos injects a single compact `Current time: …` line in the configured
timezone (weekday, time, zone, and numeric UTC offset computed from one captured
epoch) as model context. The default is IST (`Asia/Kolkata`). The Claude implementation injects on every user prompt and refreshes
mid-turn via the throttled PostToolBatch hook (once per batch of tool calls); the Codex implementation is
per-prompt only (UserPromptSubmit), so it has no throttle variable.
Claude stores throttle state in an owner-only directory at `$XDG_RUNTIME_DIR/chronos`, falling back to `$XDG_CACHE_HOME/chronos` and then `~/.cache/chronos`; the Codex build keeps no state.

### Knowledge (docs and memory)

The `knowledge` plugin's docs workflows (absorbed from the retired
`creating-docs`) expose no user-customizable docs-specific environment
variables. They do consume the shared `KNOWLEDGE_PANE_NAME` writer identity:
session-workspace owns it for panes it launches, while standalone callers may
set it explicitly. Plugin-root values and validator target directories are
runtime or command inputs rather than persistent configuration.
Memory-store surfaces honor `KNOWLEDGE_MEMORY_HOME` (explicit store target) and
`KNOWLEDGE_INBOX_RETENTION_DAYS` (capture-inbox retention, default 30).

Standard shell/runtime inputs such as `HOME`, `TMPDIR`, `TMUX`, `TMUX_PANE`,
`PLUGIN_ROOT`, and `CLAUDE_PLUGIN_ROOT` are not plugin-specific customization
variables. Test-only fault-injection variables and shell-local implementation
variables are intentionally omitted.

Knowledge automatic recall is opt-in and independent of Claude/Codex native
memory. `KNOWLEDGE_AUTO_RECALL` selects session and/or prompt injection;
prompt seeds need a strong lexical field score or two distinct prompt terms.
`KNOWLEDGE_AUTO_RECALL_GRAPH` is a separate strict gate (only `1`, `yes`,
`on`, or `true`). With `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE=selective` (the default),
it adds at most two active outgoing depth-one neighbours from the top two direct
seeds, only when a queried prompt term matches the text surrounding the link
(exactly or by a shared six-letter prefix). Direct hits keep their priority;
related rows identify the seed and matching link text. `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE=all` restores the prior inbound/outbound
expansion and stale-node demotion. Both modes retain result and byte caps.
Invalid graph gates, invalid modes, and helper failures suppress expansion.
This conservative filter reduces noise; it can miss useful weak-overlap links
such as “ship” versus “shipping”. See the [evaluation contract](plugins/knowledge/scripts/fixtures/README.md)
for the frozen original and independent corpora and their limitations.

These tunables bound hook recall and implicit/optional-hook capture. The
defaults are chosen to keep injected context small, so raise them deliberately.

Capture limits accept one to six decimal digits (0–999999), including leading
zeros; invalid or oversized values fall back to defaults rather than disabling
the limit. The pending/session caps are enforced for `source: auto_capture`;
manual explicit capture retains its existing behavior.

Writer exit 7 means a capture-policy refusal (missing evidence or a pending
capacity limit). `memory-remember.sh` propagates it. `memory-auto-capture.sh`
reports per-candidate refusals on stderr but exits 0; its exit status alone
does not establish that a candidate was captured.

| Variable | Claude | Codex | Default | Purpose |
|----------|--------|-------|---------|---------|
| `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE` | Yes | Yes | `selective` | With graph enabled, filter outgoing links using queried-term evidence; `all` restores unfiltered expansion. Other values disable graph expansion. |
| `KNOWLEDGE_AUTO_RECALL_LIMIT` | Yes | Yes | `5` | Maximum recalled memories injected per pass. |
| `KNOWLEDGE_AUTO_RECALL_TERMS` | Yes | Yes | `4` | Maximum salient prompt terms queried per pass. |
| `KNOWLEDGE_AUTO_RECALL_BUDGET` | Yes | Yes | `4000` | Byte cap on the injected recall block. |
| `KNOWLEDGE_AUTO_CAPTURE_LIMIT` | Yes | Yes | `3` | Maximum candidates accepted into the capture inbox per pass. |
| `KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING` | Yes | Yes | `20` | Pending inbox capacity for automatic capture; checked again under the writer lock. |
| `KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT` | Yes | Yes | `5` | Pending automatic candidates per originating session, enforced under the writer lock. Unknown sessions share one bucket; consolidation or dismissal frees capacity. |
| `KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES` | Yes | Yes | `4096` | Hard per-candidate raw-byte cap. |
| `KNOWLEDGE_CONSOLIDATE_NUDGE` | Yes | Yes | Unset (off) | Off unless set to a non-empty value other than `0`, `no`, `off`, or `false`. When on, shows the user a reminder (a Stop `systemMessage`) to run `/knowledge:consolidate` while pending candidates remain; the turn ends normally. Reviewed dismissals are retained separately and do not trigger reminders. Silent on any error. |
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
  check-commit-trailers.sh      # Rejects Co-Authored-By/Claude-Session lines

.githooks/commit-msg            # Same check for local commits (core.hooksPath)
.claude/settings.json           # Claude Code project settings: no attribution

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

CI checks `actionlint` and `zizmor` use upstream binaries pinned by version and
SHA-256 in `scripts/workflow-tools.json`. To reproduce either check on Linux
x86_64 or macOS ARM64 (Python 3 and ShellCheck required for actionlint):

```bash
python3 -B scripts/install-workflow-tools.py --tool actionlint --dest .tmp/workflow-tools
python3 -B scripts/install-workflow-tools.py --tool zizmor --dest .tmp/workflow-tools
python3 -B scripts/test-workflow-assurance.py --tool actionlint --bin-dir .tmp/workflow-tools
python3 -B scripts/test-workflow-assurance.py --tool zizmor --bin-dir .tmp/workflow-tools
```

Each check runs passing and faulty controls before scanning every workflow.
Zizmor runs offline with the regular persona, all severity/confidence levels,
and no configuration or suppression comments; online and stricter-persona
audits are outside this gate. Actionlint also checks embedded shell using the
installed ShellCheck; Python snippets are outside its scope. A download,
checksum, control or workflow failure fails the check. These are CI-only tools.
The native CLI job uses `.github/tools/codex/package-lock.json` with `npm ci`;
update its exact Codex dependency and lockfile together. Tool-pin updates need
review of the upstream release, asset digests and controlled-test results.
These checks do not themselves enable repository merge protection.


- Keep provider-specific manifests separate.
- Keep Claude command behavior aligned with the corresponding Codex skills and
  provider-parity command references.
- Codex exposes plugin skills as invocable `$plugin:skill` workflows. Treat
  `codex/plugins/<name>/commands/*.md` as provider-parity reference documents,
  and always ship a skill twin for runtime behavior.
- Codex hooks must live at `codex/plugins/<name>/hooks/hooks.json` (a plugin-root `hooks.json` is silently ignored by the runtime). Hook commands must use the runtime-provided `PLUGIN_ROOT`; never derive a plugin root from the session cwd or pin a marketplace-cache version.
- Every hook declares what its output is for in
  `scripts/test-hook-output-contracts.py`: model context, a notice for the
  user, continuing a Stop turn, gating a tool call, or nothing. The test runs
  each hooks.json command in both trees, bare and in scenarios that make it
  print, and checks the output against what Claude Code 2.1.325 and Codex
  0.169.0 accept for that event (`scripts/hook_contracts.py`) and against the
  declared intent. For example, a reminder meant for the user must be a
  `systemMessage`, and only a hook declared to continue the turn may print a
  Stop `decision`. A new hook without a declared intent fails the release
  check.
- Codex skills resolve scripts relative to the selected installed `SKILL.md` source. They must not rely on `CODEX_PLUGIN_ROOT`, which is not guaranteed in model-launched shell commands.
- Interactive/destructive workflows use Codex `request_user_input` when that capability is available and fall back to a direct blocking question with default-cancel semantics. Claude keeps the matching `AskUserQuestion` flow.
- Shared ideas can be documented in `docs/`, but runtime files should remain provider-local. `docs/` is gitignored, so those notes stay machine-local and are never published with the marketplace.
- Generated logs such as `firebase-debug.log` are ignored and should not be committed.
- Run `bash scripts/validate-release.sh` before publishing plugin updates, and
  `bash scripts/test-provider-parity.sh` when changing scheduler or context
  behavior on either side. CI runs both, plus every plugin's smoke tests and
  `shellcheck --severity=warning` over all `*.sh`, on push to `main` and on
  pull requests.
- CI splits those suites across parallel shard jobs (`release-checks`,
  `plugin-manifests`, `smoke-claude-scheduler`, `smoke-claude-workspace`,
  `smoke-claude-policy`, `smoke-codex-workspace`, `smoke-codex-policy`,
  `smoke-plugins`, `knowledge-evals`). The session-workspace and
  harness-policy suites run on separate runners, since together they took
  17 to 20 minutes against a 20-minute job timeout.
  `plugin-manifests` runs `claude plugin validate --strict` on every Claude
  plugin and on the marketplace, with Claude Code pinned in
  `.github/tools/claude` (2.1.325) and run from its platform package with
  install scripts off. The `validate-release` check passes
  only when every shard succeeds, and `validate-release.sh` fails if a shard is
  missing from that gate. A new push to a pull request cancels the pull
  request's older run. Runs on `main` are never cancelled.
- Commit messages must omit `Co-Authored-By` and `Claude-Session`. The `commit-trailers`
  job checks the full message of every commit added by a pull request or pushed to `main`.
  Either key at the start of a line, including an indented line, fails `validate-release`.
  Blocking a merge also depends on GitHub requiring that check. Enable the local hook
  with `git config core.hooksPath .githooks`. This replaces the clone's `.git/hooks` path.
- Review the rendered pull request description for attribution, session links and private
  project details before publishing. The commit check reads commit messages only.
  The tracked `.claude/settings.json` configures local Claude Code through
  `attribution.commit`, `attribution.pr` and `attribution.sessionUrl`.
- Write the squash message by hand. GitHub can include commit bodies and author
  trailers in a generated message. CI checks the resulting commit on `main` after merge.
- `claude plugin validate <path>` checks a single plugin or marketplace manifest
  against the Claude schema, which is a faster inner-loop check than a full
  release validation.
- `python3 -B scripts/test-codex-install.py` installs all seven plugins into a
  disposable Codex home and checks skill names, duplicate wrappers, and helper
  references. It makes no model calls.
- `python3 -B scripts/plugin-evals.py` validates portable `evals/*/case.json`
  scenarios without model calls. The root runner's `expectations.executions`
  grades completed command events, exit codes, counts, optional argument constraints,
  trusted helper paths and pre/post whole-plugin content digests;
  `json_contains` checks resulting JSON fields. Optional `postcheck` scripts
  inspect actual artifacts and pinned scaffold baselines. Claude-native
  `case.yaml` graders do not enforce these extra fields. Opt into native Claude
  probes with `--provider claude --plugin knowledge --run --max-cases 3
  --max-cost-usd 1 --timeout 180 --output <local-report.json>`.
  The runner splits this ceiling between cases and supplies each native process
  with `--max-budget-usd`. Codex model runs are unavailable until its native
  execution interface provides an enforceable cost ceiling; static validation
  and deterministic Codex tests remain available.
  Cases can specify genuine `followups` with later prompts or manifest-bound
  approval replies. The runner rejects approval fixtures unless the preceding
  model turn displayed the current manifest hash. It retains native events,
  eligible artifact hashes and decoded-text snapshots, per-turn checks, and
  reported cumulative cost. Reports include conversation content; use a private
  output location. An output within this repository must be git-ignored.
  Event retention is capped at 8 MiB. Artifact retention is capped at 100 files,
  100,000 bytes per file and 2 MiB total, with at most 1,000 entries inspected.
  Reports identify skipped artifacts and truncated scans.
  Probes use disposable stores, disable external integrations, and retain the
  child workspace sandbox. On macOS, run from a normal terminal if an enclosing
  sandbox prevents the child sandbox from starting. Model grades are report-only;
  deterministic script suites remain the blocking checks. Event observations cannot
  detect modify/run/restore or shell startup/function shadowing, and do not
  authenticate execution. Claude probes disable all hooks, so spontaneous-recall
  cases measure skill selection, not prompt-hook injection. The isolated Claude
  environment supports native login, `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN`.
  Custom config directories, proxy/CA settings, and Bedrock/Vertex credentials
  are not passed through. Unsupported authentication produces an execution or infrastructure error.
  Native hook injection requires a separate trusted-hook test.
- Follow [the plugin writing guide](shared/PLUGIN_WRITING.md) for new or changed
  procedural prose. This selectively applies ASD-STE100 clarity principles;
  it does not require dictionary compliance or certify the plugins.
  The guide covers authored result, approval, recovery, and handoff text plus
  shared technical terms. Exact helper output and protocol fields stay unchanged.
  Run `python3 -B scripts/lint-plugin-prose.py --changed-from <commit>` for
  advisory checks on changed tracked prose, or pass Markdown files explicitly
  to include new files. With no arguments it scans tracked authoring surfaces.
  `--json` emits a structured report. Style findings return exit 0; input errors
  return nonzero. The checker never edits files and is not an STE validator.
  Its deterministic controls run with `python3 -B scripts/test-plugin-prose.py`.
  Use the [comparison procedure](shared/PROSE_EVALUATION.md) to assess behavior;
  fixture validation alone does not establish a benefit from wording changes.
- Claude's matching scenarios include native prompts, graders, and scaffolds.
  Run from the plugin directory with `claude plugin eval . --scaffold --no-publish
  --runs 1 --ablation none --max-cost-usd 3`; use the native trust/tool options
  appropriate to the reviewed fixture. Generated `evals/results/` reports stay
  local and are gitignored.
- `session-scheduler` is intentionally a file-backed ledger layered on `session-chat`; keep scheduling state out of the transport plugin.
- `session-workspace` owns tmux lifecycle, the optional role-policy harness and the `reviewed-git-v1` workflow in schemas 4–6. The project's root `workspace.sh` is a bootstrap. `workspace.json` supplies validated pane and Git coordinates. Correlated session-chat replies and the pinned scheduler ledger record gate evidence. Product-specific checks belong in `AGENTS.md`, and the user gives the required confirmations in conversation.

### Peer orchestrators (schema 6)

Enable the harness and set `peers.session` to the declared root orchestrator session.
From a user terminal, `workspace start development-2 --no-attach` creates a copy of
`development`. Inside either orchestrator, `workspace start --checkout web --role executor`
starts its worker in a separate tmux window. From a user terminal the same worker
command also requires `--owner PANE`. Use `workspace show NAME` to bring it beside
its owner and `workspace hide NAME` to move it back. Both keep the running process.

Read `workspace plan --running --json` for worker names, owners, and checkouts.
Use `workspace status --json` for live visibility. A held worker name or checkout
reports its holder and exits 3. A reached orchestrator or worker limit exits 1.
Finish queued work before reusing a name under another owner.

Use session-workspace 0.17.1 or later on both providers to protect the configured
task ledger while peer orchestrators have no workers. A schema 6 config
without `peers` retains schema 5 behavior. For migration and rollback, stop the
current sessions under their current config before changing it.
[Example config](codex/plugins/session-workspace/templates/workspace-peers.json) · [Configuration and migration](codex/plugins/session-workspace/skills/session-workspace/references/environments.md#peer-orchestrators-schema-6)

### Independent workspace environments (schema v5)

Session-workspace supports independently named development/services groups for
multiple child repositories, optional local orchestrators under a root coordinator,
scoped task/routing checks, and multiple browser profiles. See the
[environment contract](codex/plugins/session-workspace/skills/session-workspace/references/environments.md)
and [complete sample](codex/plugins/session-workspace/templates/workspace-multi-environment.json).
Use `workspace start --environment web`, `workspace status --environment vue3`,
or `workspace restart --environment vue3 --services`. Upgrade both providers
before opting into v5. From workspace 0.15.0, declare a unique `branch` for every environment
on a linked worktree. A primary checkout also needs one when another configured
environment shares its Git directory. Set it to the local worktree branch and use the same value for an
orchestration target’s `work_branch` in that environment.

#### Root-scoped environment orchestrators

The [shared-root fixture](codex/plugins/session-workspace/scripts/fixtures/valid/shared-root-orchestrators-v5.json)
and [template](codex/plugins/session-workspace/templates/workspace-shared-root.json)
put two masters at `.` with separate workers in `component-a` and `component-b`.
An unbound root master is optional; without one, every worker environment must
name its own master. Each root-scoped master routes to its own workers and any
other master, while workers route only to their owner. Root edits and the usual
root shell floor remain available; all child-checkout mutations and `git push`
remain blocked, with existing guard packs applied.

`sessions[].panes[].runtime` (v5) is a declared `runtimes` key or `shell`. It takes
precedence over `roles.<role>.runtime`; omission inherits the role. Harness panes
cannot resolve to `shell`, and browser-selected panes must resolve to `shell`.
This supports mixed providers under the same role without changing role policy.
The existing Codex enforce caveats still apply.

Task creation requires `--meta environment=<own-id>`; assignment checks that
metadata on the stored task and permits only that master's workers. `root` is
reserved for an unbound root master. When it manages an environment directly,
its executor and reviewer accept the root's `environment=root` task tag. Shared-root writes remain user-coordinated;
no new master lock is added. Service panes with commands stay in their environment
checkout; command-less shells/browser panes can use any project-contained cwd.
Those shells carry no harness policy, so checkout confinement protects no role
boundary.

`browsers[]` uses `chrome/<project.id>/sessions/session-<sid>` instead of the singular
`browser` profile at `chrome/<project.id>`. Doctor reports INFO and a manual copy
command when the legacy directory exists and the session profile does not. Stop
Chrome before copying; exclude `sessions/` because the destination is inside the
legacy directory. No profile migration runs automatically.

For migration from two v4 configs, merge sessions, preserve pane names, choose one
`stores.base`, and restart all sessions. Stop the retired second project with its
old config first to release port allocations owned by its old project id. Keep the
old configs; rollback requires stopping merged sessions before restoring them.

The shared-root template has no unbound root orchestrator. Run workspace
installation, browser MCP configuration (`workspace browser-config --browser
services` or `vue3-services`) and shared-store cleanup from a user terminal outside
the harness, or configure an unbound root to own those operations. Root-scoped
masters retain these helper restrictions; do not unset launcher identity to bypass
them. In mixed topologies, a root-scoped master can message a confined master, but
the confined master cannot reply directly; use the unbound root as relay when one
exists. See the shared-root template's adjacent `workspace-shared-root.md` notes.

Session-workspace 0.12.0 removes the optional Jev integration. Before upgrading,
remove top-level `integrations`, each environment's `jev` field, and `integrations`
from `stores.pin` in schema-v5 configurations. Validation rejects these removed
fields with a migration diagnostic. Environment grouping and `--environment`
remain supported.
