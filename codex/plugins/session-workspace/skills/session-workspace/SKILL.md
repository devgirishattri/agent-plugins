---
name: session-workspace
description: "Understand the session-workspace plugin's config-driven tmux lifecycle commands (doctor/plan/start/status/stop/restart/reconcile). Use before invoking any session-workspace skill so you pick the right one and know the safety gates."
---

# Session Workspace

`session-workspace` is a shared engine that replaces hand-maintained
per-project `workspace.sh` launchers. Instead of several near-identical
scripts drifting independently, one engine reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it.

The engine is implemented. It validates config, renders mutation-free plans,
starts/stops/reconciles managed tmux sessions and panes, builds Claude/Codex
argv, pins non-secret coordination env, and runs read-only diagnostics.

## Choosing A Skill

| Use case | Skill | Notes |
| --- | --- | --- |
| Health/dependency check | `$session-workspace:workspace-doctor` | Read-only |
| Preview what start would do | `$session-workspace:workspace-plan` | Mutates nothing |
| Bring the workspace up | `$session-workspace:workspace-start` | Sessions/panes/agents/services |
| Check current state | `$session-workspace:workspace-status` | Read-only |
| Tear the workspace down | `$session-workspace:workspace-stop` | Destructive, needs `--confirmed` |
| Stop then start | `$session-workspace:workspace-restart` | Destructive; stop confirmation is passed internally |
| Repair drifted tmux state | `$session-workspace:workspace-reconcile` | Only sanctioned adoption path |

## Configuration Model

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
  `split_tree` layout kind for hand-built layouts a named layout can't express
- `secrets` — an owner-only env file; authorized panes receive a private 0600
  single-use transfer file whose path is embedded in the launch script, then
  the pane exports the values and unlinks the file
- `behavior` — `default_start_target`, attach, stop-scope/save, and
  session-chat helper behavior

`workspace.schema.json` documents the shape, and `validate-config.sh` is the
authoritative validator. Validation includes unknown keys, bad names, invalid
commands, path escape, secret-file gates, dangerous permission modes, and
grant/store consistency.

## Safety Gates

- `workspace-plan`, `workspace-status`, and `workspace-doctor` are read-only.
- `workspace-start` and `workspace-reconcile --apply` take a project lock and
  refuse to repurpose occupied unmanaged panes unless `--adopt --confirmed` is
  present. A same-named tmux session with no managed marker is also refused
  unless `--adopt --confirmed` is present; preview session-level adoption with
  `$session-workspace:workspace-reconcile TARGET --adopt --confirmed`, then
  apply it with
  `$session-workspace:workspace-reconcile TARGET --apply --adopt --confirmed`.
- A bare `workspace-start` uses `behavior.default_start_target` (default
  `all`); an explicit positional target always wins.
- `workspace-start` attaches only after a fully successful run, controlled by
  `behavior.attach` (`if_terminal` or `never`). `--no-attach` suppresses
  attach regardless of config.
- `--no-agents` and `--no-services` create and mark panes without launching
  their runtimes; those panes are reported `[claimed]`, not healthy, and a
  later start without the suppression flag launches them.
- If the session-chat helper cannot resolve and
  `behavior.session_chat_helper.on_missing` is `fail`, `workspace-start`
  aborts before taking the lock or touching tmux; `warn` starts anyway with a
  warning.
- `workspace-stop` requires `--confirmed` and kills only tmux sessions marked
  for the current `project.id`.
- Secrets never travel through tmux history, argv, or session env; only a
  private single-use file path is passed to the launch script.
