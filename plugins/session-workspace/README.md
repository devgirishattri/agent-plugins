# session-workspace

Config-driven tmux workspace engine. One shared engine, driven by a
project-local `.agent-workspace/workspace.json`, replaces a hand-maintained
per-project `workspace.sh` launcher script.

## Problem it solves

A tmux-based multi-agent project typically needs a launcher script that
creates named sessions and panes, starts an orchestrator/executor/reviewer
agent in each with the right model/grants/environment, wires up shared
coordination stores (messages, tasks, context snapshots), and can tear
everything down again. When every project hand-rolls that script, the
scripts drift: one project's `stop` kills more than another's, one forgets
to pin an environment variable another relies on, one develops a bug the
others already fixed. `session-workspace` factors the ~85% that is identical
across projects into one engine, and expresses the ~15% that legitimately
differs — session/pane layout, per-role grants and models, which
coordination stores are exported, memory topology, secrets — as fields in a
versioned JSON config.

A project adopts the plugin by creating `.agent-workspace/workspace.json`
and a thin bootstrap shim (`workspace.sh`) at its root. All behavior
lives in the plugin; the project-local shim contains no project logic at
all — see "Bootstrap shim" below.

## Lifecycle verbs

All verbs are exposed as both a Claude command (`/workspace-doctor`, etc.)
and, in the Codex tree, a matching skill. From a shell they are reached as
`workspace <verb> [args...]` once the `install` verb has put the dispatcher on
your `PATH` (or `./workspace.sh <verb>` in a project carrying the older
per-project shim — see "The two entry points"). `workspace --contract` prints
the CLI contract string both entry points use for their compatibility check.

| Verb | Signature | Mutates tmux? | Purpose |
|---|---|---|---|
| `doctor` | `workspace-doctor [--config PATH] [--json]` | Never | Read-only health check: tooling versions, config validity, plugin dependency versions, pane cwds, secrets-file gates, state-dir writability, runtime resolution, coordination-base drift, session-chat helper resolution. |
| `plan` | `workspace-plan [TARGET\|all] [--config PATH] [--json]` | Never | Deterministic dry-run: resolves and prints exactly what `start` would do (sessions, panes, argv, env var *names*, grants) without touching tmux. |
| `start` | `workspace-start [TARGET\|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]` | Yes | Creates only what is missing. A pane the engine already manages and is healthy is left alone (idempotent restart). |
| `status` | `workspace-status [TARGET\|all] [--config PATH] [--json]` | Never | Reports session/pane/role/runtime/model/cwd/process/health for every planned pane. |
| `restart` | `workspace-restart [TARGET\|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]` | Yes | `stop --confirmed` followed by `start`, for the same target. Unlike the old launchers, `restart` accepts `--no-save`. |
| `reconcile` | `workspace-reconcile [TARGET\|all] [--config PATH] [--apply] [--adopt --confirmed]` | Only with `--apply` | Dry-run by default; `--apply` repairs missing/misnamed managed resources without respawning healthy panes. Use `--adopt --confirmed` to preview adoption, then add `--apply` to perform it; `start --adopt --confirmed` is the direct lifecycle alternative. |
| `stop` | `workspace-stop [TARGET\|all] [--config PATH] [--no-save] --confirmed [--all]` | Yes | Kills only tmux sessions carrying this project's managed marker. Refuses outright without `--confirmed`. |
| `install` | `workspace-install [--target PATH] [--dry-run]` | Never (no tmux, no config) | Installs this plugin's `templates/workspace-dispatcher.sh` to `~/.local/bin/workspace` so `workspace <verb>` works machine-wide. Idempotent — an identical target reports `already current` and writes nothing, so it doubles as the refresh for that copy. Backs up any existing target to `<target>.bak`, verifies the result answers `--contract`, reports PATH membership, and prints (never writes) the `alias ws=workspace` line. |
| `browser-config` | `workspace-browser-config [--config PATH] [--provider codex\|claude\|all] [--apply] [--json]` | Never | Derives project-scoped Codex and Claude MCP entries from `browser`. Dry-run by default; `--apply` writes and backs up project config files, but never touches tmux, and refuses conflicting unmanaged entries. |
| `harness-status` | `harness-status [--config PATH] [--json]` | Never | Read-only view of the opt-in harness (mode/profile/roles/gates/guards) and whether this pane's engine identity matches the validated plan. |
| `harness-doctor` | `harness-doctor [--config PATH] [--json]` | Never | Read-only checks for config, activation, all bundled hook registrations, schema-v3 guards, `python3`, and live identity. Non-zero only on `ERROR`. |

`TARGET` is a `sessions[].id` from the config, or `all` (the default).
`--json` output on `plan`/`status`/`doctor` is produced from the same
computation as the human-readable form, so the two can never disagree.

`stop` also sends `Ctrl-C` to every managed, non-idle pane and waits
`SESSION_WORKSPACE_STOP_GRACE_SECONDS` (default `5`) before force-killing the
session, so an in-flight agent/service gets a chance to shut down cleanly.

## Safety model

- **Managed markers.** Every session and pane the engine creates carries a
  `@session_workspace_*` tmux option (`@session_workspace_project`,
  `@session_workspace_session`, `@session_workspace_pane`,
  `@session_workspace_role`, `@session_workspace_runtime`). These markers,
  not a name match, are the sole authority for "did this engine create it."
- **`=NAME` exact-match targeting.** Every tmux existence/target check uses
  `=NAME` (tmux's exact-match session syntax), never a bare name, which tmux
  prefix-matches. This closes a defect present in the hand-maintained
  launchers, where `tmux has-session -t NAME` could silently match a
  same-prefixed session belonging to something else.
- **Never renaming an unmanaged pane implicitly.** If a planned pane slot is occupied
  by a pane the engine doesn't recognize (no matching marker), `start`
  leaves it completely untouched and reports the slot as failed with
  guidance, rather than repurposing it. Explicit adoption is available either
  through `workspace-start --adopt --confirmed` or through the recommended
  review-first flow: preview with `workspace-reconcile --adopt --confirmed`,
  then apply with the same command plus `--apply`.
- **Never adopting an unmanaged session implicitly.** A tmux session whose
  name matches the config but which carries no managed marker — the state
  every session predating this plugin is in — is refused the same way, and
  the refusal names the command that actually adopts it. With
  `--adopt --confirmed`, the session adoption plan (name, window, existing
  pane count, panes already carrying markers) is printed first. `start`
  adopts directly when given `--adopt --confirmed`; `reconcile` adopts only
  with `--apply`, so its default dry run changes nothing.
- **`--confirmed` gates.** `stop` refuses to run at all without
  `--confirmed`. `--adopt` (on `start` or `reconcile`) requires `--confirmed`
  too — adoption without review is never allowed.
- **Marker-scoped stop.** `stop` only ever kills a session that carries
  *this project's* marker value. A same-named session that isn't marked as
  ours is reported as skipped, never touched. `behavior.stop_scope` controls
  breadth: `"selected"` (default) stops only the target session(s);
  `"all"` (or the `--all` flag) widens to every session on the server
  carrying this project's marker, including ones the current config no
  longer lists.
- **Secrets never touch argv, `send-keys`, or tmux metadata — but they do
  transit one private file.** See "Secrets" below.
- **Project-scoped locking.** `start`, `reconcile --apply`, and `stop`
  acquire an `mkdir`-based lock (with pid file and stale-lock reclaiming) per
  `project.id` under the state directory, so two concurrent invocations
  can't race on the same splits or marker writes.

## Secrets

`secrets.env_file` (relative to `project.root` unless absolute) holds
`KEY=value` lines and is parsed literally — it is never `source`d or
`eval`'d, so a malicious value like `x=$(rm -rf ~)` stays inert text.
`workspace-doctor` and `validate-config` both gate it: it must be mode
`0600`, owned by the current user, **not** a symlink, resolve inside the
project root, and be git-ignored. A config that fails any of those gates
fails validation outright.

Delivery is not "secrets never touch disk" — it is a private, single-use,
0600 temp file whose **path** (never the value) is embedded into the
target pane's own launch script. That script is what actually reads the
file, using shell builtins (`read`/`export`, never `.`/`source`/`eval`),
exports each `KEY` into *that pane's own* process environment, and unlinks
the file immediately. The path travels as a plain argv element to `bash -c`
— it is never tmux-parsed, logged, or interpolated into a `send-keys` call
(the historical bug this design specifically fixes: a secret token
interpolated into `send-keys` lands in shell history and pane scrollback).
`tmux set-environment -h` (hidden session env) is deliberately **not** used
for secrets, because hidden variables are documented to never propagate
into the environment of new processes — only regular (non-secret) pinned
env uses that mechanism (see `env.groups.*.pin_to_session` below).

`secrets.allow` is the list of keys a pane may request; `secrets.visible_to_roles`
restricts which *roles* ever receive a secret file at all — a role absent
from that list gets no file, so it can never see any key regardless of
`allow`. `secrets.on_missing` (`"warn"` or `"fail"`) controls what happens
when an allowed key isn't present in the file or the caller's environment
(the caller's environment is checked first, then `env_file`; a value in the
caller's environment wins): `"fail"` aborts
that pane's launch outright; `"warn"` starts the pane without it.

## Harness and shared guard packs (opt-in, schemas v2/v3)

`schema_version: 2` adds one optional, typed `harness` block that turns the
workspace into a fail-closed multi-agent harness: one **orchestrator** pane,
and per child checkout one **executor** / **reviewer** pair, with an
executable role policy enforced by a `PreToolUse` hook on both providers.
Everything else in the config is unchanged between v1 and v2; an existing
v1 config keeps working with no edits (a v1 config with a `harness` key is
rejected).

`schema_version: 3` is v2 plus optional, declarative `harness.guards`.
Without `guards`, a v3 normalized plan and policy decision are byte-identical
to v2. Guard packs centralize reusable project hooks without accepting a
script, command, regex, or permission exception.

**Activation is explicit.** The hook is a true no-op — no Python is even
spawned — for: a session with no `SESSION_WORKSPACE_CONFIG` (not launched
by this engine), a schema-v1 config, a v2/v3 config with no `harness` block,
and `harness.enabled: false` (which must then carry no `mode`/`profile`/
`roles`/`gates`/`guards` siblings) — provided the pane's launcher mode
(`SESSION_WORKSPACE_HARNESS_MODE`) is empty. A pane launched while the
harness was `audit`/`enforce` still carries that mode after the config is
disabled; that is drift, and it intentionally blocks until the pane is
restarted. Only `enabled: true` with `mode` (`audit` | `enforce`),
`profile: "strict-v1"`, `roles`, and `gates` activates it.

### Per-pane engine identity

Every pane the engine launches receives six base **engine-owned** variables;
a guarded schema-v3 launch receives `SESSION_WORKSPACE_GUARDS_JSON` as a
seventh. They live in the pane's own process environment — never mirrored into the tmux
session env, never settable from `env.groups`/`pane_name_aliases` (both are
validation errors) — and `workspace-plan` lists their names:

| Variable | Value |
|---|---|
| `SESSION_WORKSPACE_CONFIG` | absolute, canonical path of the config the pane was launched from |
| `SESSION_WORKSPACE_PROJECT_ROOT` | canonical project root |
| `SESSION_WORKSPACE_PANE_NAME` | the pane's configured name |
| `SESSION_WORKSPACE_ROLE` | the pane's configured role name |
| `SESSION_WORKSPACE_PANE_CWD` | the pane's resolved cwd |
| `SESSION_WORKSPACE_HARNESS_MODE` | `audit` or `enforce` when active; empty for v1, no `harness`, or `enabled: false` |
| `SESSION_WORKSPACE_GUARDS_JSON` | canonical guard JSON for a guarded v3 launch; absent for v1/v2 and v3 without guards |

The policy cross-checks this identity against the validated config on every
gated tool call and **fails closed** on any disagreement: unknown pane, role
or cwd mismatch, project-root mismatch, `SESSION_CHAT_PANE_NAME` /
`KNOWLEDGE_PANE_NAME` disagreeing with the engine name, a config that no
longer validates, or config drift (harness enabled/disabled/mode-changed
after launch). Integrity failures block in **both** modes — `audit` only
softens policy denials. The remedy for drift is always a pane restart
(`workspace restart`), never editing the variables by hand.

### Schema-v3 shared guards

All packs are optional and additive. Policy denials follow `harness.mode`;
health/lifecycle packs only add non-blocking context. Today they provide:

- `protected_files`: for the orchestrator Edit/Write/NotebookEdit/apply-patch
  family within the project root, deny `.env`, `.env.*`, common JS/PHP lockfiles,
  `google-services.json`, and generic service-account/Firebase JSON names.
  `extra_basenames` adds exact basenames only; it cannot remove defaults.
- `orchestrator.deny_child_chdir`: deny `cd`/`chdir`/`pushd` and reviewed
  `env -C`/`--chdir` hops into a configured child checkout. `git -C` and
  `make -C` remain command options, not process-directory changes.
- `lifecycle.session_reminder` and `.prompt_reminder`: generic role/routing
  context on SessionStart and UserPromptSubmit; no project command names.
- `workspace_health` runs only in the configured orchestrator pane.
  `warn_root_dirty`: at Stop, report root working-tree
  changes; `.warn_missing_panes`: report missing **non-optional**, non-service
  agent panes; `.branch_ahead`: for executor child roots with both configured
  local branches, report the neutral fact that `release` is ahead of `base`.

The lifecycle/health wrappers exit silently before jq/Python when the guarded
v3 launcher identity is absent or the feature is off. Lifecycle reminders use
event-specific `hookSpecificOutput.additionalContext` JSON on both providers.
Stop checks are bounded, skip non-git roots and absent refs, and never block
stopping.

### The strict-v1 floor (immutable, not configurable)

Configuration selects *which* panes hold each role; it cannot add scripts,
regexes, shell fragments, commands, or permission exceptions. The floor:

- **Reviewer** — every edit/write/patch/notebook tool is denied. Shell is
  default-deny, with two carve-outs: (a) one literal read-only command
  (`cat head tail wc ls stat file diff grep rg find jq sort ...` and
  read-only `git` subcommands without write/output/external-exec options)
  whose path operands — including bare `.`/`..`, `-C` values, and quoted
  paths containing spaces — resolve inside its own checkout, the
  coordination stores the plan grants it, either provider's message inbox,
  or the *selected version* directory of an installed plugin (a bare
  operand naming a planted symlink is canonicalized) — no pipes,
  redirection, expansion, unquoted globs, `cd`, wrappers or assignment
  prefixes, path-written executables, `sed`/`awk`/`perl`, `tail -f`,
  `find -exec`, or reads of sibling checkouts via `../`; (b) trusted
  coordination helpers (below): session-chat send/dispatch/reply to the
  orchestrator only, scheduler `task-done`/`task-block` (never `--force`,
  never `task-new`/`task-assign`), context save/share/load/list/search/diff,
  read-only knowledge recall/search/graph/lint/doctor. Never memory/docs
  writes.
- **Executor** — edit targets must resolve (through symlinks) inside its
  configured pane cwd. Arbitrary shell stays available for builds/tests/git
  inside the checkout, but every path-like operand must resolve inside that
  cwd (absolute, `../`, bare `..`, quoted paths with spaces, `-C`/`--chdir`
  values, and symlink escapes alike) — the fixed `/dev/null` sink/source is
  the only exempt operand; `cd`/`chdir`/`pushd`/`popd` are
  tracked across a composed command so later operands resolve against the
  directory the shell would actually be in, and a `cd` whose target leaves
  the cwd (or `cd -`, a bare `cd`, `pushd` with no operand) is refused;
  operands that only exist after a shell expansion (`"$TARGET"`, backticks,
  unquoted globs/braces) fail closed; redirection targets (`> file`,
  `>> "escape link"`, `2> /tmp/x`, `< ../x`) are path operands too;
  attached `-C..`/`-Cdir` and `--chdir=` values are resolved; a bare operand
  that names an existing entry (a planted symlink) is canonicalized;
  `xargs`, inline code (`bash -c`, `python -c`, `node -e`, `eval`), and any
  sandbox/approval-escape flag are refused. Outbound
  coordination may only target
  the orchestrator; direct `tmux send-keys`/`paste-buffer`/... and copied or
  relative session-chat helpers are refused as routing bypasses. Executors
  additionally get `task-review` and `memory-remember`.
- **Orchestrator** — may not edit or run mutating commands against any
  child checkout root (read-only commands and `git` reads against a child
  are fine), and never runs `git push` — including behind `env`, `command`,
  `exec`, `nohup`, or an assignment prefix (pushes go through the owning
  executor and the project's own release gate); `cd child && ...`,
  `git -Cchild`, `make -Cchild`, `env --chdir=child` and write
  redirections into a child count as child mutations; its own root, the
  config,
  and files outside the workspace are not otherwise gated. Its shell is
  otherwise free. It owns `task-new`/`task-assign`
  (only to configured executor/reviewer panes), `tasks-clean`,
  `messages-clean`, memory/docs writes, and every workspace mutator.
- **Unknown tools are allowed** for every role (`Read`, `Grep`, `Glob`,
  `WebFetch`, ...). Classification is by tool *name*, never by the shape of
  the payload, so the plugin is a floor, not a tool allowlist.
- **One literal wrapper grammar for any role.** The launch wrappers
  `parse_wrappers` recognizes, and the complete set of options it accepts:
  `NAME=value` prefixes (any number, at any hop); `env` with
  `-i`/`--ignore-environment`, `-u NAME`/`--unset NAME`/`--unset=NAME` (a
  literal variable name), `-C DIR`/`-CDIR`/`--chdir DIR`/`--chdir=DIR` (a
  literal directory; nested `env -C` hops compose in order, each resolved
  through symlinks against the previous hop and checked, while a repeated
  `-C`/`--chdir` within one `env` behaves like `env` itself — the last
  value wins, against that `env`'s starting cwd — with every given value
  still checked), `NAME=value` assignments, and a terminating `--`;
  `command CMD` (`command -v`/`-V` is a lookup query, not a wrapper);
  `builtin CMD`; and bare `exec CMD`, `nohup CMD`, `time CMD` with no
  options. An unsupported, missing, or dynamic wrapper option — `exec -a`/
  `-l`/`-c`, `nohup --`, `time -o`/`-p`, `/usr/bin/time -o`,
  `env -S`/`--split-string=` (a re-parsed argv), `env -u` without a name,
  `env --unset=` with an empty or invalid name, `env --default-signal`,
  `command -p`, `builtin -x` — is refused (`shell.wrapper`), and the
  privilege wrappers `sudo`, `doas`, `su`, `runuser`, `pkexec` at any hop
  (`env sudo`, `command doas`, `FOO=1 sudo`, a later segment) are refused
  outright (`shell.privilege`) — a privileged or re-parsed argv is never
  modelled.
- **No permission-widening escape hatch for any role**: a shell command
  carrying `--dangerously-bypass-approvals-and-sandbox`,
  `--dangerously-bypass-hook-trust`, `--dangerously-skip-permissions`, or
  `--permission-mode bypassPermissions` (a nested agent launch) is refused
  everywhere, matching the engine's own refusal of those flags in
  `runtimes.*.args`.
- **Read roots are exact, and scoped by surface.** A *reviewer's* shell
  operands, and *trusted-helper* operands for any child role (a dispatch
  prompt file, `--store`, a context snapshot), may resolve inside: the
  pane's own cwd; the coordination stores the plan *grants* that pane
  (`roles.<r>.grants`, i.e. the same directories it receives as
  `--add-dir`); `~/.claude/messages` and `~/.codex/messages`; and the
  *selected version* directory of an installed plugin (never another
  version, never an unselected plugin). An *executor's* arbitrary shell is
  narrower still: every operand must resolve inside its pane cwd alone
  (`/dev/null` excepted).
  Inherited `SESSION_*_HOME` / `SESSION_CHAT_TARGET_MESSAGES_DIR` values
  and the rest of a marketplace cache are deliberately not trusted. A plain `memory-search.sh --recall`
  without `--store` still works for a pane without a memory grant (the
  script resolves its own store); only an explicit `--store` outside the
  granted roots is refused.
- **Child routing is master-only.** Children address only the orchestrator;
  the orchestrator addresses only its configured executor/reviewer panes;
  `broadcast-message.sh` has no topology-bound form and is not allowed in
  strict-v1.

### Trusted helpers: exact provenance, literal argv

For **every role**, an installed-plugin helper is recognized only as one
literal, uncomposed `bash <script> args...` segment where `<script>` is the
canonical path of the **selected** installed version under
`~/.claude/plugins/cache/girishattri-plugins/<plugin>/<version>/scripts/<name>.sh`
or the Codex equivalent under `~/.codex/plugins/cache/...`. Rejected: any
prefix or wrapper (`FOO=1`, `env`, `exec`, `sh`), operators, pipes,
redirection, `$`/backtick expansion outside single quotes, multi-line
arguments, `..`/`~`/unnormalized paths, a symlink at any component below the
cache root, a stale or unselected version, a script from another
marketplace or a copy elsewhere, and any basename without a reviewed argv
grammar. "Selected" means: on Claude, the `installPath`/`version` recorded in
`~/.claude/plugins/installed_plugins.json` (user scope, or a project scope
whose `projectPath` is this workspace); on Codex, the plugin enabled in
`~/.codex/config.toml` at the version of the marketplace manifest under
`~/.codex/.tmp/marketplaces/`. Every allowed helper carries an exact
per-basename argv grammar (`harness-policy.py`'s `HELPERS` table) — there is
no grammar-less pass for any role.

### The hook

`hooks/hooks.json` registers `scripts/harness-hook.sh` on `PreToolUse` for
`Edit|Write|MultiEdit|NotebookEdit|Bash`. The wrapper exits 0 without
touching Python whenever the harness is inactive; when it is active and
`python3` is missing it fails closed (exit 2). `scripts/harness-policy.py`
(stdlib only, runs on the stock macOS Python 3.9) then:

- allows silently (exit 0, no output);
- in `audit` mode reports one `AUDIT by session-workspace strict-v1
  [rule]: reason (would deny in enforce mode)` line and exits 0 for a
  *policy* denial — it never blocks those; identity, config, and drift
  *integrity* failures still exit 2 in audit mode. **On Claude** that line
  goes to stderr. **On Codex 0.151** stderr of a successful (exit 0) hook is
  discarded, so the Codex registration invokes the same policy with
  `--codex-hook-output`, which renders the identical audit text as exactly
  one inert, compact JSON object on stdout — top-level `systemMessage`
  only, never `hookSpecificOutput`/`permissionDecision`/`updatedInput`, so
  it can never widen a permission. The option changes rendering only; the
  decision (`--decision-json`) is byte-identical with and without it. The
  Claude registration never passes it;
- in `enforce` mode prints one `BLOCKED by session-workspace strict-v1
  [rule]: reason` line to stderr and exits 2, which blocks the tool call —
  on both providers.

`harness-policy.py --decision-json` (test/parity mode) prints exactly one
compact, key-sorted JSON object —
`{"active","decision","mode","pane","profile","reason","role","rule","tool"}`
with `decision` ∈ `allow | deny | audit` — so both provider trees can
byte-compare decisions. Both Claude-shaped (`tool_name`/`tool_input`, string
`command`) and Codex-shaped (`shell`/`apply_patch`, argv-list or `bash -lc`
commands, `workdir`, JSON-string `tool_input`) payloads are understood.

For guarded schema-v3 launches, the same manifest also registers generic
`SessionStart`/`UserPromptSubmit` reminders and the non-blocking Stop health
check. Claude and Codex health output is a top-level `systemMessage` JSON
object; Codex rejects non-empty plain-text Stop stdout. Codex trusts each hook entry by hash, so upgrading to a
release that adds or changes these entries requires accepting/re-trusting the
new session-workspace hook hashes before relying on them.

The exact Codex 0.151 shell hook shape is: `tool_name` `"Bash"` (Codex
canonicalizes `exec_command` to that name), a *string* `tool_input.command`,
and a top-level absolute `cwd` (the turn's cwd) — with **no**
`tool_input.workdir`. Codex does not expose the per-call `exec_command`
workdir in `PreToolUse`, and non-shell reads are not gated by this policy at
all, so **Codex `enforce` must not be described as complete path
containment**: a per-call workdir the policy never receives cannot be
validated. `audit` is the recommended Codex mode until the runtime exposes
that information or a sound mitigation exists.

### Harness known gaps (0.4.1)

- The policy re-validates the config by running `workspace-plan.sh --json`
  on every gated tool call (a jq-only plan; the hook is registered on the
  gated tools only). There is deliberately no cache: a same-uid cache file
  could be planted by an executor.
- Reviewer verdicts travel as single-line `send-message.sh` replies or
  scheduler notes — a reviewer cannot stage a multi-line dispatch body
  because every write tool is denied. Executors stage prompt files inside
  their own checkout; a trusted helper may consume a pre-existing literal
  `$TMPDIR` file as input, but containment refuses creating one there.
- Executors read dispatch files with the provider's `Read` tool (unknown
  tools are allowed); `cat ~/.claude/messages/...` from an executor shell is
  refused by the cwd containment floor. Executors stage dispatch prompt
  files *inside their own checkout* — edit and shell containment refuse
  creating files under `$TMPDIR`; a temp file that already exists (written
  by a helper or hook) is accepted as helper input only.
- `harness-status`/`harness-doctor` probe `harness-policy.py` directly, so
  their `policy:`/`identity.live` verdict is the policy *engine's* decision
  for this process — it assumes the bundled hook is actually loaded and
  trusted by the provider, which the plugin cannot verify from inside a
  pane. `hook.registration` only checks that the bundled `hooks/hooks.json`
  registers `PreToolUse`; provider-side trust prompts (Codex) or plugin
  enablement (Claude) are outside its reach.
- Outside the global gates (escape flags, exact trusted-helper provenance
  and grammar, master-only routing), arbitrary orchestrator shell is gated
  only by the child-root floor and the `git push` denial; project
  release/build rules stay in `AGENTS.md` and project hooks.
- Codex `PreToolUse` carries no per-call `exec_command` workdir (only the
  turn's top-level `cwd`), so executor/reviewer shell containment on Codex
  is incomplete for commands that set their own workdir; see "The hook".
- Codex "selected version" resolution needs `~/.codex/config.toml` plus the
  marketplace manifest; on Python < 3.11 (no `tomllib`) a minimal
  line-based reader handles the `[plugins."<name>"]` table.

## The bootstrap shim

The per-project alternative to the machine-wide dispatcher (see "The two entry
points" above for which to choose — usually the dispatcher).

`templates/workspace.sh` is copied verbatim into a project as
`<project-root>/workspace.sh`. It contains zero project-specific logic —
all real behavior lives in the plugin's own `scripts/workspace.sh`. On
every invocation it:

1. Resolves `PROJECT_DIR` from `${BASH_SOURCE[0]}` and exports
   `SESSION_WORKSPACE_CONFIG=$PROJECT_DIR/.agent-workspace/workspace.json`.
2. Resolves the plugin root, in order: `$SESSION_WORKSPACE_PLUGIN_ROOT` (an
   explicit override) → the newest **contract-compatible** version under
   the Codex plugin cache (`~/.codex/plugins/cache`) → the newest
   contract-compatible version under the Claude plugin cache
   (`~/.claude/plugins/cache`). Versions are discovered on disk and ordered
   with `sort -V` — no literal version string is ever hardcoded in the shim.
   "Contract-compatible" means running that candidate's
   `scripts/workspace.sh --contract` prints exactly `session-workspace-cli 1`;
   a candidate that doesn't match is skipped, not just picked and hoped
   for.
3. If neither cache yields a compatible install, it exits with both the
   Codex and Claude install commands, and a pointer to
   `SESSION_WORKSPACE_PLUGIN_ROOT` as a manual override.
4. `exec bash "$root/scripts/workspace.sh" "$@"`.

## Adopting it in a new project

**Once per machine** (not per project):

1. Install the plugin (Claude: `claude plugin install session-workspace@girishattri-plugins`;
   Codex: `codex plugin add session-workspace@girishattri-plugins`).
2. Run `workspace-install` (the `install` verb) to put the machine-wide
   dispatcher on your `PATH` as `workspace`. From then on `workspace <verb>`
   works inside **any** configured project — see "The two entry points" below.

**Then, per project:**

3. Create `.agent-workspace/workspace.json` (`schema_version: 1`, `2` for the
   harness, or `3` for optional shared guards — see "Harness" above) describing
   the project's runtimes, roles, stores, sessions/panes, and behavior — see
   `scripts/workspace.schema.json` for the documented shape, or copy one of
   `scripts/fixtures/valid/*.json` as a starting point, and the
   "Configuration reference" section below for the full field list.
4. **Recreate any coordination directories the config expects by hand.**
   The engine does not create them for you — see "known limitations".
5. Run `workspace doctor` and fix everything it reports as `ERROR`
   (`WARN` is advisory).
6. Run `workspace plan` and check it matches the topology you intended
   — this step mutates nothing, so it's safe to iterate on.
7. Run `workspace start` to bring the workspace up.

Nothing is copied into the project: adoption is the config file plus whatever
coordination directories it expects. There is no per-project script to keep in
sync, and no file to go stale when the engine changes.

## The two entry points

The engine can be reached two ways. Both resolve the plugin identically —
newest version first, each candidate contract-checked with
`scripts/workspace.sh --contract` against `session-workspace-cli 1`, no version
string hardcoded anywhere — and neither ever pins a marketplace name.

| | `templates/workspace-dispatcher.sh` | `templates/workspace.sh` |
|---|---|---|
| Installed as | `~/.local/bin/workspace`, once per machine | `<project>/workspace.sh`, once per project |
| Installed by | the `install` verb | copying it yourself |
| Serves | every configured project | the project it sits in |
| Finds the config by | the engine's upward walk from `$PWD` | pinning `SESSION_WORKSPACE_CONFIG` to its own directory |
| Refresh when the template changes | `install` again (idempotent; `upgrade.sh` can call it unconditionally) | re-copy by hand, per project |

**Prefer the dispatcher.** The shim exists for the case where a project must be
pinned to its own config regardless of `$PWD`, or where you cannot rely on
`PATH` — a CI job invoking `./workspace.sh` by relative path, for instance. It
is not deprecated; it is simply the narrower of the two.

Both are optional. The plugin's own commands and skills (`/workspace-*` on
Claude, `$session-workspace:workspace-*` on Codex) resolve the config the same
way, so a project with neither entry point installed still works from inside an
agent session. What the dispatcher adds is a workspace launchable by a human, a
shell script, or CI with no provider CLI in the loop.

## Known limitations

These are honest gaps in the current (0.4.1) implementation, not aspirational
roadmap items — read them before depending on the behavior they describe.

- **`stores.memory.root` does not export `KNOWLEDGE_MEMORY_HOME`.**
  `coordination_var_name()` (both in `adapters.sh` and `compute-plan.jq`)
  only maps `messages`/`scheduler`/`contexts` to an exported env var;
  `"memory"` is not a valid `stores.pin` entry (schema-rejected) and has no
  corresponding export at all. If a project wants its panes' `knowledge`
  memory store to actually point at `stores.memory.root`, it must restate
  that same path as a value in `env.groups.<g>.values` (e.g.
  `"KNOWLEDGE_MEMORY_HOME": "${PROJECT_ROOT}/.agents/memory"`). Nothing
  keeps that restated value and `stores.memory.root` in sync — if you change
  one without the other, they silently diverge and the memory store a pane
  writes to differs from the shard the config claims to use.
- **The engine never creates coordination directories.** The old
  hand-maintained launchers each did their own `mkdir -p` /
  `chmod 700` of the `messages`/`scheduler`/`contexts` directories under
  `stores.base` (and the memory root) before starting panes. This engine
  does not — the only directories it creates are its own state directory
  (`$XDG_STATE_HOME/session-workspace/<project-id>/`, 0700), the tmux lock
  directory, and — only when a `browser` block is configured — the derived
  Chrome profile directory (`browser.profile_dir`, created by
  `workspace-start.sh` before launching the browser session). Coordination
  directories are never among them. On a machine where those coordination directories already
  exist from a prior run this is harmless; on a genuinely fresh clone it
  means the first agent to write to an unmanaged store, or a strict
  consumer of one, can fail until something creates the directory.
- **A freshly split "extra" pane keeps the invoking cwd.** `_sw_split_extra_pane`
  (used to fill a gap when a session has fewer existing panes than the plan
  needs) calls `tmux split-window` without `-c`, so the new pane inherits
  the split source's cwd, not the pane's configured `cwd`. Normally this is
  invisible because the pane is immediately respawned with `-c` set from
  the plan. But with `--no-agents` (on `start`/`reconcile`) or a
  service-role pane under `--no-services`, `_sw_launch_pane` returns before
  that respawn ever runs — so a pane created that way is left sitting in
  whatever directory the split happened from, not the configured `cwd`.
- **A pinnable env var is inexpressible without also session-mirroring
  it.** `env.groups.<g>.pin_to_session` is a single boolean that gates two
  things at once: whether that group's values (plus the `stores.pin`
  coordination vars) are exported into the pane's *own* process
  environment at all, and whether that same subset is additionally
  mirrored into the tmux *session* environment for later, unmanaged panes
  to inherit. There is currently no way to say "export this into the
  pane's own env, but don't mirror it session-wide" — the two travel
  together.
- **`workspace-doctor`'s post-config checks are skipped, correctly, once
  config validation fails — and the exit code reflects that failure.**
  Every check after `config.validation` (pane cwds, secrets-file gates,
  state dir, runtime resolution, coordination-base drift, session-chat
  helper) is gated on validation having actually passed, so none of them
  run against data that couldn't be trusted (an unresolved `project.root`,
  a malformed `stores.base`, etc.). The `config.validation` check itself
  counts as an `ERROR` in that case, which does correctly non-zero the
  process exit code — `doctor` does not report a false "clean" green exit
  when the config is broken.

## Configuration reference

`.agent-workspace/workspace.json`, `schema_version: 1`, `2`, or `3` (v2 adds
the harness; v3 adds optional shared guards). Structural shape,
required-ness, and cross-field rules are enforced by `validate-config.sh`
(`validate-structural.jq` for the pure-jq structural half, plus filesystem
checks in `validate-config.sh` itself for path containment and the secrets
gates); `scripts/workspace.schema.json` documents the same shape for
reference but is not executed by anything.

Two interpolation tokens are recognized in any string value, and nowhere
else: a literal `${PROJECT_ROOT}` **prefix** is replaced with the config's
canonicalized project root, and a literal `${PROJECT_ID}` **substring**
(anywhere) is replaced with `project.id`. No other `${...}` text, env-var
expansion, or shell substitution happens anywhere in the config.

### `browser` (optional)

This binds one existing, one-pane service session to a persistent Chrome
DevTools instance. That pane must omit `command` and `port`; the engine derives
both so the endpoint has one source of truth.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `browser.session_id` | string | yes | Existing one-pane session whose required `service` role uses the built-in `shell` runtime. |
| `browser.port` | integer, 1–65535 | yes | Loopback DevTools port. Start records machine-local ownership and refuses a live allocation owned by another project. |
| `browser.chrome_program` | string | yes | Chrome executable name or absolute path. `doctor` checks resolution without executing it. |
| `browser.mcp_package` | exact `chrome-devtools-mcp@x.y.z` | yes | Pinned MCP package; floating tags such as `@latest` are rejected. |
| `browser.mcp_server_name` | `A-Za-z0-9_-` | no | MCP entry name; default `chrome-devtools`. |

The Chrome argv always binds `127.0.0.1`; its profile is derived as
`${XDG_CACHE_HOME:-$HOME/.cache}/session-workspace/chrome/<project.id>`.
`start` waits for `/json/version`, while `status` and `doctor` report endpoint
readiness. `workspace browser-config` previews the Codex/Claude MCP entries;
`workspace browser-config --apply` backs up and merges them. Start the browser
session before opening a new Codex or Claude session.

### `project` (required)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `project.id` | string, `^[a-z0-9][a-z0-9-]*$` | yes | — | Slug used for session-name prefixes, the state directory, and managed marker values. |
| `project.display_name` | string | no | `project.id` | Human-readable name shown in `plan`/`status` output. |
| `project.root` | string | yes | — | Path to the project root, resolved relative to the directory containing `.agent-workspace/` (or the config file's own parent, if loaded from an unconventional location). Every pane `cwd` and coordination-store path is validated to resolve inside this root. |

### `runtimes` (required, object keyed by runtime name)

Named launch profiles. A pane's role picks one of these by key; there is no
free-form "custom command" anywhere, and no interactive runtime menu — what a
pane launches is entirely decided by the config, so `plan` can show it exactly
and `start` is reproducible.

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `runtimes.<name>.program` | string | yes | — | Executable name or path (looked up on `PATH` if not absolute). |
| `runtimes.<name>.args` | array of strings | no | `[]` | Static argv appended after `program`, before any engine-built flags. Validated to never contain a dangerous flag (see below). |

The runtime *key* itself (e.g. `claude`, `codex`) is what a role's
`roles.<r>.runtime` field references. A `roles.<r>.runtime` of `shell`
is always available and does not need a `runtimes.shell` entry — it
launches the pane's interactive shell (or, for a service pane, its
configured `command`) with no engine-built agent flags at all.

### `roles` (required, object keyed by role name)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `roles.<r>.runtime` | string | yes | — | A key from `runtimes`, or `shell`. |
| `roles.<r>.agent.model` | string | no | no flag emitted | Passed as `--model VALUE` (claude and codex). `"inherit"`, `"null"`, or omitted all mean "emit nothing" — resolved identically to an omitted value. |
| `roles.<r>.agent.effort` | string | no | no flag emitted | Claude: `--effort VALUE`. Codex: `-c model_reasoning_effort=VALUE`. Same `"inherit"`/omitted-means-nothing rule. |
| `roles.<r>.agent.profile` | string | no | no flag emitted | Claude: `--agent VALUE`. Codex: `-p VALUE`. Same rule. |
| `roles.<r>.agent.permission_mode` | enum: `inherit`, `default`, `plan`, `acceptEdits`, `dontAsk` | no | no flag emitted | Claude only, emitted as `--permission-mode VALUE`; never emitted for codex even if set. `bypassPermissions` is **not** in the allowed enum at all — it is rejected at the schema level, and `adapters.sh` additionally refuses to build argv containing it even if fed unvalidated input directly (defense in depth). |
| `roles.<r>.grants` | array of strings | no | `[]` | Store names (`messages`, `scheduler`, `contexts`, `memory`) this role's agent panes receive as `--add-dir` grants. Only applies to non-`shell` runtimes — a shell-role pane never gets engine-built `--add-dir` flags. A store not listed here is never granted to that role, regardless of `stores.pin` (see `grants-unpinned-store` validation below). |
| `roles.<r>.env_group` | string | no | `"none"` | Key into `env.groups`. `"none"` resolves to `{values: {}, pin_to_session: false}` if that key isn't defined. |

`agent.model`/`effort`/`profile`/`permission_mode` can also be set **per
pane** (`sessions[].panes[].agent.*`), which takes precedence over the
role-level value; an `"inherit"` at either level defers to the next level
down, and both omitted resolves to no flag.

### `stores` (required)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `stores.base` | string | no | `.tmp` | Coordination-store root, relative to `project.root` unless absolute. Must resolve inside the project root (lexically, and — for whatever portion already exists on disk — physically, so a symlink can't smuggle it out). |
| `stores.pin` | array, enum of `messages`/`scheduler`/`contexts`, unique | yes (key must be present; may be `[]`) | — | Which coordination stores get exported as env vars (`SESSION_CHAT_TARGET_MESSAGES_DIR`, `SESSION_SCHEDULER_HOME`, `SESSION_CONTEXT_HOME` respectively) at all. These three var names are rejected outright if they appear literally in any `env.groups.*.values` — `stores.pin` is their only source of truth, so the two can never disagree. |
| `stores.overrides` | object, string values | no | `{}` | Per-store path override, keyed by store name (`messages`/`scheduler`/`contexts` — any other key is accepted structurally but has no consumer). Overrides `stores.base + "/" + store` for that one store. Also validated to resolve inside the project root. |
| `stores.memory.mode` | enum: `shared`, `per-pane` | no | `shared` | `shared`: every granted pane gets the same memory root. `per-pane`: each pane gets its own subdirectory (see `shard` below). |
| `stores.memory.root` | string | no | `.agents/memory` | Memory store root, relative to `project.root` unless absolute. Validated to resolve inside the project root. **Produces no env export** — see known limitations. |
| `stores.memory.shard.strip_prefix` | string | no | `""` | Only used when `mode: per-pane`. A literal prefix stripped from the pane name to derive its shard subdirectory (typically `"${PROJECT_ID}-"`, already interpolated by the time it's used). |
| `stores.memory.shard.strip_suffixes` | array of strings | no | `[]` | Suffixes stripped from the (already prefix-stripped) pane name, in list order, first match wins per suffix. |
| `stores.memory.shard.fallback` | string | no | `master` | Shard name used when stripping prefix/suffixes leaves an empty string. |

When `stores.memory.mode` is `per-pane`, every dev pane name must start with
`"${project.id}-"` — enforced structurally, not just as a shard-naming
convention.

### `env` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `env.groups.<g>.values` | object, string values | yes if the group exists | — | Extra `NAME=value` pairs exported into every pane whose role's `env_group` is `<g>`. Keys must match `^[A-Z_][A-Z0-9_]*$` (config validation rejects a key that does not) and must not name a reserved `SESSION_WORKSPACE_*` identity var (also rejected by validation). A key that collides with one of the three engine-always identity vars (`TMUX_PANE`, `SESSION_CHAT_PANE_NAME`, `KNOWLEDGE_PANE_NAME`) passes validation but is ignored by the `adapters.sh` renderer: the engine-always value is set last and wins. The renderer also drops a charset-invalid name with a warning, but that is defense in depth for a direct, unvalidated invocation — normal config validation has already rejected it. The engine also always ships a fixed `KNOWLEDGE_AUTO_*`/`KNOWLEDGE_CONSOLIDATE_NUDGE` default block (identical across every adopter today); values here override those defaults by name. |
| `env.groups.<g>.pin_to_session` | boolean | no | `false` | See "known limitations" — gates *both* whether this group's values (plus the `stores.pin` coordination vars) are exported into the pane's own process env, and whether that same subset is mirrored into the tmux session environment via `tmux set-environment` (non-hidden, session-scope) so a later, unmanaged pane in that session inherits it too. |
| `env.pane_name_aliases` | array of strings | no | `[]` | Extra env-var names, each set to the pane's own name (replaces a project's bespoke `<PROJECT>_CODEX_PANE_NAME`-style variable). Same charset rule and engine-always collision rule as group values. |

Three variables are **engine-always** and never config-driven, at any
level: `TMUX_PANE` (re-pinned to the real target pane id after respawn),
`SESSION_CHAT_PANE_NAME`, and `KNOWLEDGE_PANE_NAME`. They are computed last
and win unconditionally over anything a group value or alias tried to set.
`KNOWLEDGE_PANE_NAME` in particular is an authorization boundary for who
may write to the memory store, so it is also never one of the vars
mirrored into session env — a session-scoped identity would let a
hand-added pane in that session present itself as a different pane.

### `secrets` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `secrets.env_file` | string | yes if the block exists | — | Relative (to `project.root`) or absolute path to a `KEY=value` file. Gated as described in "Secrets" above. |
| `secrets.allow` | array of strings, `^[A-Za-z_][A-Za-z0-9_]*$` | no | `[]` | The only keys any pane may ever request from `env_file`. |
| `secrets.visible_to_roles` | array of strings | no | `[]` | Roles whose panes receive a secret-transfer file at all. A role not listed here gets nothing, regardless of `allow`. |
| `secrets.on_missing` | enum: `warn`, `fail` | no | `warn` | Behavior when an allowed key is present in neither the launching process's environment nor `env_file`. `fail` aborts that pane's launch; `warn` starts it without the key. |

### `sessions` (required, array, minimum 1 entry)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `sessions[].id` | string | yes | — | Stable identifier used as the `TARGET` argument to every lifecycle verb, and as the layout-persistence file key. |
| `sessions[].name` | string | yes | — | The actual tmux session name (commonly `"${PROJECT_ID}-<id>"`). |
| `sessions[].window_index` | integer ≥ 0 | no | `0` | Window index within the session that holds this session's panes. |
| `sessions[].retain_layout` | boolean | no | `false` | If true, the window's `#{window_layout}` is saved after every successful `start`/`reconcile --apply` and restored on the next one, before slot-filling — so a user's manual pane resizing survives a restart. |
| `sessions[].layout.kind` | enum: `standard`, `split_tree` | yes (if `layout` present) | — | `standard`: named tmux layout applied via `select-layout` after slot-filling. `split_tree`: an explicit, ordered sequence of splits (see below). |
| `sessions[].layout.name` | string | no | `"tiled"` | Only used when `kind: standard` — the tmux layout name passed to `select-layout`. |
| `sessions[].layout.only_when_fresh` | boolean | no | `false` | Only used when `kind: split_tree`. The split tree is built **only** when the window currently has exactly one pane; otherwise the existing panes are matched by marker/position instead (so a previously built split tree is never rebuilt on a second `start`). |
| `sessions[].layout.mask_after_split_hook` | boolean | — | (always applied for `split_tree`) | Whether the engine masks the window's `after-split-window` hook during construction and restores it byte-for-byte afterward, so a user's own tmux hooks can't interfere mid-build. This is always done for a fresh split-tree build; the field exists in the schema for documentation/explicitness. |
| `sessions[].layout.nodes` | array of `{id, from?, dir?, percent?}` | yes (if `kind: split_tree`) | — | Ordered split instructions. The first node has no `from`/`dir`/`percent` (it's the window's existing single pane). Every subsequent node splits the pane at `from` in direction `dir` (`v` or `h`) reserving `percent` (1-99) for the new pane, emitted as `-l <percent>%` (never the deprecated `-p <pct>`). |
| `sessions[].layout.pane_order` | array of node ids | yes (if `kind: split_tree`) | — | Explicit, authoritative mapping from split-tree node id to `panes[]` slot order — a visual layout can't otherwise express "pane order differs from split order." |
| `sessions[].panes[].name` | string | yes | — | The pane's `@name` (session-chat addressing identity) and managed-marker pane value. Enforced unique across the whole config. |
| `sessions[].panes[].role` | string | yes | — | A key from `roles`. |
| `sessions[].panes[].cwd` | string | no | session/window default | Relative (to `project.root`) or absolute working directory. Validated to resolve inside the project root; a missing directory is a hard validation error **unless** `optional: true`. |
| `sessions[].panes[].optional` | boolean | no | `false` | A missing `cwd` for an optional pane is reported (INFO in `doctor`, "skipped" in `start`) rather than failing validation/the slot. |
| `sessions[].panes[].command` | array of strings, min 1 item | no | (agent argv, or interactive shell) | For a `shell`-runtime (typically `service`-role) pane: literal argv to run instead of an interactive shell. A bare string command is rejected — it must be an array, so there's never a shell re-parsing step. |
| `sessions[].panes[].port` | integer, 1-65535 | no | — | First-class metadata only (surfaced in `plan`/`status` output); does not itself change what gets launched or add a `--port` flag anywhere. |
| `sessions[].panes[].agent.*` | see `roles.<r>.agent.*` | no | role-level value, or no flag | Pane-level override of `model`/`effort`/`profile`/`permission_mode`, taking precedence over the role's own value. |

### `behavior` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `behavior.default_start_target` | string | no | `"all"` | The `TARGET` a bare `start` (no positional argument) uses. `restart` is unaffected — it always forwards one explicit target to both its `stop` and `start` halves, so the two can never disagree. Must be `"all"` or one of `sessions[].id` — anything else is a validation error, so it can never surface as "unknown session target" at launch time. An explicit positional `TARGET` always wins. |
| `behavior.attach` | enum: `if_terminal`, `never` | no | `if_terminal` | Interactive-attach policy, applied by `start` only after a fully successful run. `if_terminal`: attach to the started session when stdout is a terminal — `switch-client` when already inside tmux, `attach-session` otherwise; a non-terminal (automated) run attaches nothing and reports `attach: skipped (not a terminal)`. `never`: never attach. `--no-attach` on the CLI forces it off regardless of this field. Every branch prints one `attach: ...` line, so the decision is always visible. |
| `behavior.stop_scope` | enum: `selected`, `all` | no | `selected` | `selected`: `stop`/`restart` only touch the target session(s). `all`: widen to every session on the server carrying this project's marker. `--all` on the `stop` CLI forces `all` regardless of this field. |
| `behavior.save_before_stop` | boolean | no | `false` | If true, `stop` saves the window layout (when `retain_layout: true`) and invokes tmux-resurrect's save script (if installed) before killing anything. `--no-save` on the CLI forces this off regardless of the config value. |
| `behavior.session_chat_helper.resolve` | string | no | `"always"` | `"never"` skips the session-chat helper-resolution check in `doctor` entirely (reported `OK`, not consulted). Any other value resolves the helper via the plugin cache/source tree. |
| `behavior.session_chat_helper.on_missing` | enum: `warn`, `fail` | no | `"warn"` | What happens when the session-chat helper does not resolve. `fail`: `start` aborts non-zero *before* taking the project lock or touching tmux (nothing is half-created), and `doctor` reports `ERROR`. `warn`: `start` proceeds with a warning and panes come up without inter-pane messaging; `doctor` reports `WARN`. Both verbs resolve the helper through the same function, so `doctor`'s verdict and `start`'s behavior cannot disagree. |

### `harness` (optional in schema v2; guard-capable in schema v3)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `harness.enabled` | boolean | yes (if the block exists) | `false` is inactive and must be the only key. `true` requires `mode`, `profile`, `roles`, and `gates`; schema-v3 `guards` remains optional. |
| `harness.mode` | enum: `audit`, `enforce` | when enabled | `audit` reports would-be policy denials on stderr without blocking; `enforce` blocks (exit 2). Integrity failures block in both. |
| `harness.profile` | const `strict-v1` | when enabled | The only profile. No other value is accepted. |
| `harness.roles.orchestrator` / `.executor` / `.reviewer` | string (a `roles` key) | when enabled | Exactly these three keys; three distinct existing role names; none may be `service` or use the built-in `shell` runtime. |
| `harness.gates.plan_review_ttl_minutes` / `.audit_ttl_minutes` | integer 1–1440 | when enabled | Exactly these two keys. Freshness windows for plan review and audit (reserved for the scheduler integration; validated now so they are stable config). |
| `harness.guards.protected_files.profile` | const `credentials-lockfiles-v1` | v3, if pack exists | Generic protected credential/lockfile basenames; orchestrator Edit-family only. |
| `harness.guards.protected_files.extra_basenames` | unique exact-basename array | no | Additive names matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`; no slash or glob. |
| `harness.guards.orchestrator.deny_child_chdir` | boolean | no | Deny orchestrator process-directory hops into child roots. |
| `harness.guards.lifecycle.session_reminder` / `.prompt_reminder` | boolean | no | Generic SessionStart/UserPromptSubmit routing reminders. |
| `harness.guards.workspace_health.warn_root_dirty` | boolean | no | Orchestrator-only Stop warning for root working-tree changes. |
| `harness.guards.workspace_health.warn_missing_panes` | boolean | no | Orchestrator-only Stop warning for missing non-optional, non-service panes. |
| `harness.guards.workspace_health.branch_ahead.base` / `.release` | safe literal branch names | if pack exists | Orchestrator-only neutral Stop fact per executor child root; refs are distinct, contain no `..`, and do not end in `/` or `.lock`. |

Cross-field rules for an enabled harness: exactly one non-service pane uses
the orchestrator role; every executor pane declares a non-`.` `cwd` that
does not resolve to the project root and has exactly one reviewer pane with
the identical `cwd`; every reviewer pane pairs with exactly one executor.

### Argv-safety rules validated regardless of the above

These aren't config fields, but they explain why certain otherwise-valid-looking
config values get rejected:

- Any static arg in `runtimes.<r>.args`, and any resolved
  `agent.permission_mode`, is rejected if it matches a hard-coded dangerous
  set: Claude's `bypassPermissions` (any spelling — bare, `--permission-mode`
  flag, or `=`-joined), and codex's
  `--dangerously-bypass-approvals-and-sandbox` /
  `--dangerously-bypass-hook-trust`.
- `env.groups.*.values` keys, `env.pane_name_aliases` entries,
  `secrets.allow` entries, and `secrets.visible_to_roles` entries are all
  charset-restricted (uppercase-snake-case for env names, identifier shape
  for secret keys) specifically so a value can never be crafted to break out
  of the rendered `export NAME=VALUE;` string the pane's shell evaluates —
  even though the *value* half of that string is always `%q`-quoted, an
  unquoted, attacker-chosen *name* could still inject a second shell
  statement.
