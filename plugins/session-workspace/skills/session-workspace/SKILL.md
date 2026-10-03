---
name: session-workspace
description: When and how to use the session-workspace plugin's config-driven tmux lifecycle commands (doctor/plan/start/status/stop/restart/reconcile/install), its opt-in strict-v1 multi-agent harness (harness-status/harness-doctor, the PreToolUse role policy), and schema-v4 reviewed Git orchestration. Use this before invoking any /session-workspace:workspace-* or /session-workspace:harness-* command (including /session-workspace:workspace-orchestrator) so you understand the config model, the real flags, the safety gates, and the provider-neutral coordination boundary.
---

# session-workspace: config-driven tmux workspace engine

`session-workspace` is a shared engine that reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it: config load/validation, mutation-free planning, runtime
argv/env construction, and create/adopt/reconcile/stop/restart.

## Commands

| Command | Purpose |
|---|---|
| `/session-workspace:workspace-doctor` | Read-only dependency/config health check |
| `/session-workspace:workspace-plan` | Dry-run plan (human + JSON); mutates nothing |
| `/session-workspace:workspace-start` | Bring up sessions/panes/agents/services (idempotent) |
| `/session-workspace:workspace-status` | Current lifecycle state; mutates nothing |
| `/session-workspace:workspace-stop` | Tear down sessions/panes (destructive, needs `--confirmed`) |
| `/session-workspace:workspace-restart` | Stop then start (destructive, confirmation implicit) |
| `/session-workspace:workspace-reconcile` | Dry-run by default; `--apply` repairs drift; `--adopt --confirmed` claims unmanaged panes |
| `/session-workspace:workspace-install` | Install/refresh the machine-wide `workspace` dispatcher on PATH; no config, no tmux, idempotent |
| `/session-workspace:workspace-browser-config` | Render/apply project MCP entries for the configured browser |
| `/session-workspace:harness-status` | Read-only: is the opt-in harness active (mode/profile/roles/gates), and does this pane's engine identity match the plan |
| `/session-workspace:harness-doctor` | Read-only harness health: config validity, activation, hook registration, python3, live identity match |
| `/session-workspace:workspace-orchestrator` | Schema-v4 status/plan/dispatch/review/commit/push/deploy lifecycle using configured executor/reviewer pairs |
| `/session-workspace:verification-recipe` | Author or maintain a project-local launch/doctor/drive/evidence/cleanup recipe; guidance only, no new runtime, permission, or approval gate |
| `/session-workspace:blast-radius` | Report-only review of a diff's indirect consumers and safety assumptions, with checks only within existing authorization |
| `/session-workspace:adversarial-review` | Optional budgeted independent pass that tries to break an exact subject; evidence-based dispositions; consensus is not approval |
| `/session-workspace:benchmark-check` | Check a performance claim: comparable inputs, correctness/work counts, interleaved repeated samples, limiter, explicit inconclusive |
| `/session-workspace:behavioral-eval` | Design/assess behavioral evals: baseline, positive/negative controls, grading on completed executions and artifacts; model spend only when authorized |
| `/session-workspace:pr-status` | Read-only GitHub PR blocker report (ready/blocked/waiting/inconclusive); orchestrator-only under strict-v1; never merges or comments |

## Configuration model (enforced)

A project opts in by creating `.agent-workspace/workspace.json`
(`schema_version: 1`, `2` for the optional harness, `3` for shared guard packs,
or `4` for reviewed orchestration) describing:

- `project` — id/display name/root
- `runtimes` — named launch profiles (e.g. `claude`, `codex`), replacing any
  free-form custom-command entry
- `roles` — per-role runtime, optional `agent.{model,effort,profile}`,
  `--add-dir` grants, env group
- `stores` — which coordination stores (`messages`, `scheduler`, `contexts`)
  get exported/session-pinned, plus memory topology (`shared` vs `per-pane`)
- `sessions[].panes[]` — declarative session/window/pane plan, including a
  `split_tree` layout kind for hand-built layouts a named layout can't
  express, and `optional: true` for a pane whose `cwd` may not exist yet (an
  un-cloned child repo) — such a pane is skipped, never launched with a
  wrong/inherited cwd
- `secrets` — an owner-only (mode 0600, git-ignored) env file, gated by
  `secrets.allow` / `secrets.visible_to_roles` / `secrets.on_missing`
- `behavior` — attach/stop-scope/save defaults
- `browser` — optional Chrome DevTools binding: `session_id` plus, when that
  session has more than one pane, `pane_name` naming the single pane that
  receives the Chrome argv (a one-pane session may omit it); pinned MCP
  package, loopback port, and portable derived profile. Only the selected pane
  reports DevTools readiness; siblings keep their own `command`/`port`
- `harness` (schema v2/v3/v4) — opt-in strict-v1 role policy: `enabled`,
  `mode` (`audit`|`enforce`), `profile`, the three semantic `roles`, and
  `gates`, plus optional schema-v3/v4 `guards`; absent or `enabled: false` is a true no-op (for panes whose
  launcher mode is empty — a pane launched under audit/enforce keeps that
  mode and blocks as drift until restarted)
- `orchestration` (schema v4 only) — optional closed `reviewed-git-v1`
  targets. It binds a safe child cwd to its configured executor/reviewer pair,
  named remote, work/release branches, and fixed merge strategy; it accepts no
  commands, scripts, prompts, regexes, or custom gate bypasses.

`workspace.schema.json` in `scripts/` documents this shape, and
`validate-config.sh` enforces it — both structurally (via
`validate-structural.jq`: unknown/missing keys, name uniqueness, env var
naming, permission_mode allowlist, etc.) and against the filesystem (cwd/
symlink escape checks, the secrets file's location/mode/ownership/
git-ignore state).

### Secret delivery

From 0.8.0, `secrets.allow` accepts strings and closed objects with required
`key` and `roles` fields, for example
`["SHARED_TOKEN", {"key":"MCP_TOKEN","roles":["master"]}]`.
Strings inherit `secrets.visible_to_roles`; objects receive its intersection
with their own `roles`. The global list is always a ceiling. Omitted/empty
global visibility or empty per-key roles grants nothing. Role names reference
the configured `roles` map, not fixed semantic role labels. Unknown roles,
duplicate object role names, duplicate keys (exact, case-sensitive across both
forms), invalid identifiers, unknown object fields, and missing/null object
fields fail validation. Keys match `^[A-Za-z_][A-Za-z0-9_]*$`.

Both secret-file delivery and the explicit single-key lookup authorize before
resolving values. `on_missing` applies only to entitled keys; a missing
master-only token cannot warn or block executor delivery. Lookup denials name
the allowlist, global ceiling, or per-key roles rule without revealing value
presence. Plan reports `secret_keys_by_role` and each pane's `secret_keys` as
names only. Doctor reports effective names by role and keys with no recipient;
for object/mixed configs its file checks cover only effective keys and name
affected roles. Legacy string-only doctor file checks still scan every key.
Doctor is workspace-wide and diagnoses the file; caller environment overrides
still apply at delivery. The authorized `secret-value` command intentionally
returns the resolved value; never use it to populate reports or logs.

Migration: existing unique-key string configs need no change. Before adding a
role to global visibility, convert keys that role must not receive to object
entries in the same edit. Update both providers, inspect plan/doctor, then
restart affected panes and MCP processes. No `schema_version` or store migration
is required. Restore a safely restricted string-only config before downgrading;
never flatten object entries into strings under a widened global list. This
controls workspace delivery, not same-user filesystem access or independently
inherited credentials.

A secret is delivered to exactly one pane's spawned PROCESS environment via
a private, single-use, mode-0600 file: `adapters.sh secret-file` resolves
and gates it (`secrets.allow` / `visible_to_roles` / `on_missing`), writes
`KEY=VALUE` lines to that file, and returns only its PATH — never the
value. The pane's launch script reads that path with shell `read`/`export`
BUILTINS (never `.`/`source`/`eval`, so a value can never be re-parsed as
code), exports each var into that pane's own process environment, and
unlinks the file immediately. Nothing ever goes through `tmux
set-environment` (hidden or plain), `send-keys`, or argv — a hidden tmux
variable is never passed into a new process's environment, and a plain one
is both session-scoped (every later pane would inherit it) and readable by
any pane via `show-environment`.

Non-secret env that a role's `env_group` marks `pin_to_session: true` DOES
use plain `tmux set-environment` on purpose — that path is for coordination
vars a hand-made pane should also inherit, and secrets are excluded from it
by construction.

## The opt-in harness (schema v2/v3/v4)

With `harness.enabled: true` the engine's `PreToolUse` hook enforces an
**immutable strict-v1 floor** keyed on the per-pane identity it exports at
launch (`SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`, `_PANE_NAME`, `_ROLE`,
`_PANE_CWD`, `_HARNESS_MODE`). Relay these consequences when a user hits
them:

- A session not launched by `workspace-start`, a schema-v1 project, or
  `enabled: false` is a true no-op — nothing is gated — as long as the pane
  was not launched under an earlier `audit`/`enforce` mode (stale mode is
  drift and blocks until the configured session containing the pane is
  restarted via `/session-workspace:workspace-restart <session-id>`).
- **Draft staging (reviewer, executor, environment-scoped coordinator)**:
  from 0.7.1 the only store write is the pane's own drafts directory,
  `<messages grant>/drafts/<pane-name>/<name>.md|.txt`, when the validated
  plan grants this pane's role `messages` (the path comes from the plan,
  never from inherited `SESSION_*` env). Native create/edit/delete only;
  the parent must canonicalise to exactly that directory, so symlinked
  directories and any path (including `../` forms) resolving outside it are
  refused, as are names outside the safe-name rule, existing targets
  that are not single-link regular files, moves, other panes' drafts, the
  store top level, delivered dispatch files, `queue/`/`archive/`/ledger
  state, and any patch that also touches another path. No grant means no
  staging exception (fail closed); an executor's ordinary checkout writes are
  not a substitute staging contract. The root orchestrator's authority over
  store and transport files is unchanged. Arbitrary executor shell commands
  (outside the single literal read grammar) and confined-coordinator shell
  commands may not name a granted messages store, even one nested in their
  cwd; reviewer safe reads and an executor's single safe read of a store in
  its cwd are unchanged. Portable guidance: read dispatch files with `Read`
  or a trusted helper. Earlier releases let reviewers write any
  top-level `.md`/`.txt` in the store, which also reached other panes'
  pending dispatch files; that is removed, and downgrading restores it.
- **Reviewer**: Edit/Write/NotebookEdit/apply_patch are blocked everywhere
  except draft staging above. Shell writes remain denied. Shell is default-deny except one literal
  read-only command inside its own checkout or explicit per-pane `read_paths`
  (no pipes, redirection, `sed`, or ungranted sibling reads) and trusted coordination helpers (reply to the
  orchestrator, `task-done`/`task-block`, context and read-only knowledge
  helpers). Verdicts go out as a single-line `/session-chat:reply`, a
  scheduler note, or a staged file sent with `dispatch-to-session.sh`.
  Schema v2–5 reviewers and executors may set `sessions[].panes[].read_paths` to up to 16
  files/directories, relative to the project root or canonical absolute paths
  for external repositories. Files grant exact-file access, directories grant
  descendants. Parent traversal, overlapping grants, configured
  stores/memory/secrets, provider homes and foreign v5 environments are
  rejected at validation. A path that is missing, not a regular file or
  directory, or has a symlink component is shown as `unavailable` in
  `workspace-plan`: launch/restart/adopt of that pane is refused and a running
  pane is blocked until the path is restored; other panes and stop/status
  keep working. Recursive symlink-follow options (`rg -L`, `grep -R`/`-S`,
  `find -L`, `du -L`, `ls -L`) and directory `diff` are denied; compare
  explicit files instead. `rg` must start with literal `--no-config`
  (`rg --no-config PATTERN PATH`) so an inherited `RIPGREP_CONFIG_PATH`
  cannot add symlink following or a preprocessor; `--pre`, `--hostname-bin`
  and `--search-zip`/`-z` are denied. Relative operands resolve against the effective
  tool `cwd`/`workdir`, and helpers must run from the configured pane cwd.
  These paths affect shell reads and reviewer tool workdirs only: they do
  not grant helper-store access, native Read/Grep/Glob permissions,
  `--add-dir`, or writes; provider permissions still apply.
  `SESSION_WORKSPACE_READ_PATHS_JSON` is engine-owned launch identity, never a
  user tunable; changing or removing paths fails closed in both modes until
  the affected session is restarted. Omitted/empty paths keep old behavior.
  Hooks are not an atomic filesystem sandbox against racing same-uid swaps.
- **Message reads (0.10.0)**: executors and reviewers may read a complete
  delivered message addressed to or sent by their validated pane, or an existing
  own draft, using the existing single literal non-Git read grammar. Use the
  quoted `cat '<absolute-path>'` command printed before the incoming body;
  inline truncation is not a task-size limit. Delivered files must sit directly
  in the plan's messages grant, be private owned regular single-link files,
  and have no symlink component or `..` traversal. Parse the generated
  `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md` name against all validated
  pane names; exactly one endpoint pair must match, with this pane at one end.
  Ambiguous or removed peers fail closed. No environment override grants reads.
  Reviewers lose broad message-store and ungranted provider-inbox access.
  Peer files, queue/archive/ledger state and message-store workdirs are denied.
  Recursive reads from ancestors of the store (`rg`, `find`, `du`, recursive
  `grep`, `ls -R`) are denied; name explicit safe subdirectories, not glob
  exclusions. Own-draft native writes and coordinator behavior are unchanged.
  Claude native Read remains ungated; these operand checks do not isolate
  arbitrary program internals or concurrent same-user filesystem changes.
  Update session-chat to 0.17.13 and workspace to 0.10.0, then restart panes.
  No schema/store migration. Rollback restores the executor read failure and
  broader reviewer access.
- **Executor**: explicit per-pane `read_paths` also permit single literal shell
  reads using the reviewer read-command restrictions above (the executor's own
  checkout plus its grants; never helper stores, and message inboxes only
  under the message-read rules above). Executor
  tool workdirs must remain inside its checkout; use relative or absolute
  operands for shared docs, for example `cat ../docs/guide.md`. Grants never
  permit writes or composed shell commands outside the checkout. A command
  that fails the read grammar (for example `rg` without `--no-config`) falls
  back to ordinary executor containment, so it still runs when every operand
  is inside the checkout; that floor checks operands, not recursive traversal
  or inherited tool configuration (a known limit).
  From 0.7.1, executors can also read files in the selected installed
  `girishattri-plugins` plugin version with the same single-command read grammar, without `read_paths`
  (skills, commands, references, and scripts as data). Use separate
  `cat <absolute-path>` calls or `rg --no-config`; this grants no cache
  writes, cache workdirs, execution, unselected-version reads, or store
  access. Confined orchestrator shell behavior is unchanged. No config
  migration is needed; update the plugin and restart affected agents.
  Downgrading restores the earlier executor cache-read restriction.
  From 0.7.3, reviewers and executors can also read provider-installed skill
  documentation with the same single literal, non-`git` read grammar: Codex
  system skills (`<codex-home>/skills/.system/<skill>/`, only while the
  system-skills marker exists) and user skills (`<codex-home>/skills/<skill>/`,
  `<claude-home>/skills/<skill>/`) whose directory holds a regular `SKILL.md`.
  Files must be regular, single-link, inside that skill directory, with no
  symlink or hidden components (except `.system`). No workdirs, helper
  operands, writes, execution, or other provider-home content. Known limit:
  skills from non-`girishattri-plugins` marketplace plugins stay denied.
  From 0.7.4, paths attached to short options (`-f/x`, `-o/x`, `-uo/x`) and
  every operand after `--` are path-checked for reviewer reads, executor
  containment, and orchestrator child writes; redirection targets are checked
  against the shell cwd. `grep`/`rg`/`sort` use reviewed option tables
  (`-e/api/` stays a pattern); other commands are checked conservatively, so
  pass unusual in-scope values as separate arguments. Reviewers never get
  `sort` output options. No config migration; restart agents after
  updating; downgrading restores the 0.7.3 gap.
  Otherwise, edits and shell path operands must stay inside its own
  checkout (the fixed `/dev/null` sink/source is the only exempt operand); inline code (`bash -c`, `python -c`) and sandbox-escape flags
  are blocked; it may only message the orchestrator. Read dispatch files
  with the literal read command above and stage multiline prompt files only through draft
  staging above (checkout, scratchpad, and `$TMPDIR` staging are not the
  contract; `$TMPDIR` writes are refused by containment).
- **Orchestrator**: cannot edit or run mutating commands against a child
  checkout; routes only to its configured executor/reviewer panes;
  `broadcast` is not available under strict-v1.
- From **0.9.0**, root and confined orchestrators deny direct remote-mutating
  `gh` commands (`orchestrator.gh_mutation`) even without a child filesystem
  operand; route mutations to the executor. Reviewed reads
  (`orchestrator.gh_read`) are `run list/view`, `pr list/view/diff/checks`,
  `workflow list/view`, `release list/view` with an explicit
  `--repo`/`-R OWNER/NAME`, positional `repo view OWNER/NAME`, and
  `api repos/OWNER/NAME/...` or `api repositories/ID/...` with effective GET.
  API `-f`/`-F`/`--input` need an explicit uppercase `--method GET`/`-X GET`;
  file-backed inputs send the file contents to GitHub even on GET, and
  confined coordinators keep filesystem containment for them. Everything
  else gh-shaped is `orchestrator.gh_unsupported`: aliases, extensions,
  executable paths, env assignments, wrappers and launchers (`timeout`,
  `nice`, `find -exec`, ...), composition, expansions, redirections, stdin
  inputs, browser flags, command-line host overrides, headers, API caching, and unknown
  flags (grammar reviewed against gh 2.100.0). Use `--json`/`--jq`/`--limit`
  instead of pipes; quoted jq `|`/`?` is data. A `gh` argument to a
  non-data command (for example `git log --author gh`) is also refused.
  Executor/reviewer rules are unchanged. This is an argv guardrail for both
  orchestrator kinds, not subprocess isolation: a script file or an
  interpreter fed on stdin can still run `gh`. Scope the orchestrator pane's
  GitHub token (per-role secret visibility) where remote mutations must be
  impossible.
- From **0.11.1**, orchestrators and executors may run the knowledge
  `memory-auto-capture.sh` helper (implicit inbox-only `remember`) with
  exactly `[--store PATH] --staged FILE [--staged FILE ...]`; `--batch-dir`
  and every other argument are refused, and reviewers are denied. The
  writer, not the policy, enforces evidence presence, provenance stamping,
  and the pending caps. Each `--staged` file must pass normal literal-file
  containment. Knowledge 0.5 implicit capture needs this release under
  strict-v1; an older harness refusing capture is a compatibility limit,
  not permission to bypass it — update and restart agents, then retry.
- `sudo`/`doas`/`su`/`runuser`/`pkexec` are refused for every role at any
  wrapper hop, as is any unsupported wrapper option (`exec -a`, `nohup --`,
  `time -o`, `env -S` all fail closed); the accepted `env`/`command`/
  `builtin`/`exec`/`nohup`/`time` forms are enumerated in the plugin README.
- Installed helpers must be invoked as one literal
  `bash <selected-cache-path>/scripts/<name>.sh args...` — no env prefix,
  wrapper, chaining, expansion, stale version, or copied script.
- `audit` mode reports `AUDIT by session-workspace strict-v1 [...]` and never
  blocks a *policy* denial (on Claude as one stderr line; on Codex, which
  discards stderr for successful hooks, as one inert top-level
  `systemMessage` JSON object); `enforce` prints `BLOCKED ...` and blocks.
  On Codex the runtime does not expose a per-call shell workdir, so do not
  present Codex `enforce` as complete path containment — `audit` is the
  recommended Codex mode for now.
  Identity/config/drift integrity failures block in both modes — the remedy
  is `/session-workspace:workspace-restart <session-id>` of the configured
  session containing that pane — this kills and recreates ALL of that
  session's configured panes, not just the drifted one — never hand-editing
  the identity variables.
- In schema v3/v4, optional `harness.guards` centralize orchestrator protected
  files, child-directory hops, generic lifecycle reminders, and bounded Stop
  health warnings. Guard changes require a workspace restart because their
  canonical JSON is launcher identity.
- `warn_missing_panes` ignores `optional:true` and shell/service panes.
  Workspace-health diagnostics emit only from the configured orchestrator;
  `branch_ahead` is a neutral local-branch fact, not deploy authorization.
- After a Codex plugin upgrade that changes hook entries, accept/re-trust the
  new session-workspace hook hashes before relying on lifecycle/Stop output.
- Run `/session-workspace:harness-doctor` first when something is unexpectedly blocked.

## Reviewed orchestration (schema v4)

When `orchestration.enabled` is true, use the `workspace-orchestrator` skill
(`/session-workspace:workspace-orchestrator`). The normalized workspace plan is
the sole target map; the orchestrator coordinates and every Git mutation runs
in the target executor. The fixed lifecycle requires correlated explicit plan
approval, user confirmation, scheduler-tracked execution, reviewer-authored
explicit audit approval, and separate commit/push/deploy confirmations. Its
freshness windows come from `harness.gates`. Ledger and session-chat records
are machine-verifiable evidence; user confirmations remain conversational and
must never be described as harness-enforced.

## Safety gates worth relaying to the user

- An unmanaged pane occupying a planned slot is never renamed/respawned —
  the slot fails with guidance until `--adopt --confirmed` is used
  deliberately, and the adoption-candidate details are always shown first
  (even in `reconcile`'s dry-run, without `--apply`).
- A tmux session with the same configured name that this engine did not
  create is never touched — exact `=NAME` targeting only, never a prefix
  match.
- `stop`/`restart` never run without confirmation (`stop` refuses outright
  without `--confirmed`; `restart` implies it).
- `workspace-plan`, `workspace-status`, and `workspace-doctor` are
  mutation-free; don't hesitate to run them freely to check state.

## Schema v5: independent environments and optional diagnostics

Read [references/environments.md](references/environments.md) for named development/
services groups, optional local orchestrators, scoped routing/tasks, multiple browser
bindings, and the fully optional removable Jev diagnostic helper. Versions 1–4
retain their single-orchestrator contract. V5 pins scope identity at launch; never
export it manually. Jev stays off unless configured, and supplies no approvals.

New inherited operational tunables are `SESSION_WORKSPACE_JEV_MAX_REQUESTS` (default
0, cumulative 0–10000 request ceiling) and `SESSION_WORKSPACE_JEV_TIMEOUT_MS` (default
5000, range 1–15000). The optional pinned `integrations` store is launch-inherited
as `SESSION_WORKSPACE_INTEGRATIONS_HOME`. Full data, credential, fallback and removal
contracts are in the reference; do not upload logs merely because it is enabled.
