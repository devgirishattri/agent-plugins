---
name: session-workspace
description: When and how to use the session-workspace plugin's config-driven tmux lifecycle commands (doctor/plan/start/status/stop/restart/reconcile/install). Use this before invoking any /workspace-* command so you understand the config model, the real flags, and the safety gates.
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
| `/workspace-doctor` | Read-only dependency/config health check |
| `/workspace-plan` | Dry-run plan (human + JSON); mutates nothing |
| `/workspace-start` | Bring up sessions/panes/agents/services (idempotent) |
| `/workspace-status` | Current lifecycle state; mutates nothing |
| `/workspace-stop` | Tear down sessions/panes (destructive, needs `--confirmed`) |
| `/workspace-restart` | Stop then start (destructive, confirmation implicit) |
| `/workspace-reconcile` | Dry-run by default; `--apply` repairs drift; `--adopt --confirmed` claims unmanaged panes |
| `/workspace-install` | Install/refresh the machine-wide `workspace` dispatcher on PATH; no config, no tmux, idempotent |

## Configuration model (enforced)

A project opts in by creating `.agent-workspace/workspace.json`
(`schema_version: 1`) describing:

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
