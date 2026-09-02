---
name: session-workspace
description: When and how to use the session-workspace plugin's config-driven tmux lifecycle commands (doctor/plan/start/status/stop/restart/reconcile/install), its opt-in strict-v1 multi-agent harness (harness-status/harness-doctor, the PreToolUse role policy), and schema-v4 reviewed Git orchestration. Use this before invoking any /session-workspace:workspace-* or /session-workspace:harness-* command (including /session-workspace:workspace-orchestrator) so you understand the config model, the real flags, the safety gates, and the provider-neutral coordination boundary.
---

# session-workspace: config-driven tmux workspace engine

`session-workspace` is a shared engine that replaces hand-maintained
per-project `workspace.sh` launchers. Instead of six near-identical scripts
drifting independently, one engine reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it.

**Current status: fully implemented.** Config load/validation, mutation-free
planning, runtime argv/env construction, and tmux session/pane lifecycle
(create, adopt, reconcile, stop, restart) are all live and enforced — this
is not a scaffold.

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
- `browser` — optional Chrome DevTools session binding, pinned MCP package,
  loopback port, and portable derived profile
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
- **Reviewer**: every Edit/Write/NotebookEdit is blocked; shell is
  default-deny except one literal read-only command inside its own checkout
  (no pipes, redirection, `sed`, sibling `../` reads) and trusted
  coordination helpers (reply to the orchestrator, `task-done`/`task-block`,
  context and read-only knowledge helpers). Verdicts go out as a single-line
  `/session-chat:reply` or a scheduler note.
- **Executor**: edits and shell path operands must stay inside its own
  checkout (the fixed `/dev/null` sink/source is the only exempt operand); inline code (`bash -c`, `python -c`) and sandbox-escape flags
  are blocked; it may only message the orchestrator. Read dispatch files
  with the `Read` tool and stage prompt files inside the checkout (writes
  under `$TMPDIR` are refused by containment).
- **Orchestrator**: cannot edit or run mutating commands against a child
  checkout; routes only to its configured executor/reviewer panes;
  `broadcast` is not available under strict-v1.
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
