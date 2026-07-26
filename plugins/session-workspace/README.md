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
and a 35-ish-line bootstrap shim (`workspace.sh`) at its root. All behavior
lives in the plugin; the project-local shim contains no project logic at
all — see "Bootstrap shim" below.

## Lifecycle verbs

All verbs are exposed as both a Claude command (`/workspace-doctor`, etc.)
and, in the Codex tree, a matching skill. They also work directly through
the dispatcher: `workspace.sh <verb> [args...]`, or `workspace.sh --contract`
to print the CLI contract string used by the bootstrap shim's compatibility
check.

| Verb | Signature | Mutates tmux? | Purpose |
|---|---|---|---|
| `doctor` | `workspace-doctor [--config PATH] [--json]` | Never | Read-only health check: tooling versions, config validity, plugin dependency versions, pane cwds, secrets-file gates, state-dir writability, runtime resolution, coordination-base drift, session-chat helper resolution. |
| `plan` | `workspace-plan [TARGET\|all] [--config PATH] [--json]` | Never | Deterministic dry-run: resolves and prints exactly what `start` would do (sessions, panes, argv, env var *names*, grants) without touching tmux. |
| `start` | `workspace-start [TARGET\|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]` | Yes | Creates only what is missing. A pane the engine already manages and is healthy is left alone (idempotent restart). |
| `status` | `workspace-status [TARGET\|all] [--config PATH] [--json]` | Never | Reports session/pane/role/runtime/model/cwd/process/health for every planned pane. |
| `restart` | `workspace-restart [TARGET\|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]` | Yes | `stop --confirmed` followed by `start`, for the same target. Unlike the old launchers, `restart` accepts `--no-save`. |
| `reconcile` | `workspace-reconcile [TARGET\|all] [--config PATH] [--apply] [--adopt --confirmed]` | Only with `--apply` | Dry-run by default; `--apply` repairs missing/misnamed managed resources without respawning healthy panes. `--adopt --confirmed` is the *only* path to claiming an existing unmanaged pane. |
| `stop` | `workspace-stop [TARGET\|all] [--config PATH] [--no-save] --confirmed [--all]` | Yes | Kills only tmux sessions carrying this project's managed marker. Refuses outright without `--confirmed`. |

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
- **Never renaming an unmanaged pane.** If a planned pane slot is occupied
  by a pane the engine doesn't recognize (no matching marker), `start`
  leaves it completely untouched and reports the slot as failed with
  guidance, rather than repurposing it. The only sanctioned path to claim
  that pane is `workspace-reconcile --adopt --confirmed`, which prints the
  adoption plan (current command, existing markers if any) before acting.
- **Never adopting an unmanaged session implicitly.** A tmux session whose
  name matches the config but which carries no managed marker — the state
  every session predating this plugin is in — is refused the same way, and
  the refusal names the command that actually adopts it. With
  `--adopt --confirmed`, the session adoption plan (name, window, existing
  pane count, panes already carrying markers) is printed first, and only
  `--apply` labels it managed; a dry run adopts nothing.
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
(checked in that order — the caller's environment wins): `"fail"` aborts
that pane's launch outright; `"warn"` starts the pane without it.

## The bootstrap shim

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

1. Install the plugin (Claude: `claude plugin install session-workspace@girishattri-plugins`;
   Codex: `codex plugin add session-workspace@girishattri-plugins`).
2. Copy `templates/workspace.sh` into the project root as `workspace.sh`
   (or `workspace.sh.new` first, if a hand-maintained launcher already
   occupies that path — see "known limitations" for why you should keep a
   backup of anything untracked before overwriting it).
3. Create `.agent-workspace/workspace.json` (`schema_version: 1`) describing
   the project's runtimes, roles, stores, sessions/panes, and behavior — see
   `scripts/workspace.schema.json` for the documented shape, or copy one of
   `scripts/fixtures/valid/*.json` as a starting point, and the
   "Configuration reference" section below for the full field list.
4. **Recreate any coordination directories the config expects by hand.**
   The engine does not create them for you — see "known limitations".
5. Run `./workspace.sh doctor` and fix everything it reports as `ERROR`
   (`WARN` is advisory).
6. Run `./workspace.sh plan` and check it matches the topology you intended
   — this step mutates nothing, so it's safe to iterate on.
7. Run `./workspace.sh start` to bring the workspace up.

## Known limitations

These are honest gaps in the current (0.1.0) implementation, not aspirational
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
  (`$XDG_STATE_HOME/session-workspace/<project-id>/`, 0700) and the tmux
  lock directory. On a machine where those coordination directories already
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

`.agent-workspace/workspace.json`, `schema_version: 1`. Structural shape,
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
| `env.groups.<g>.values` | object, string values | yes if the group exists | — | Extra `NAME=value` pairs exported into every pane whose role's `env_group` is `<g>`. Keys must match `^[A-Z_][A-Z0-9_]*$`; a name that fails that check, or that collides with an engine-always identity var (`TMUX_PANE`, `SESSION_CHAT_PANE_NAME`, `KNOWLEDGE_PANE_NAME`), is dropped with a warning rather than silently accepted. The engine also always ships a fixed `KNOWLEDGE_AUTO_*`/`KNOWLEDGE_CONSOLIDATE_NUDGE` default block (identical across every adopter today); values here override those defaults by name. |
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
