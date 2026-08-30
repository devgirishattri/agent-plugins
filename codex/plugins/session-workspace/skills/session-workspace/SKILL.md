---
name: session-workspace
description: "Understand session-workspace lifecycle and its optional strict-v1 multi-agent harness. Use before invoking workspace or harness skills so you pick the right read-only or mutating surface and know the safety gates."
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
Schema v2 can additionally opt into a shared executable role-policy harness;
schema v1 and v2 configs with no enabled harness retain workspace-only behavior.

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
| Install the `workspace` command | `$session-workspace:workspace-install` | Puts the dispatcher on PATH; no config, no tmux, idempotent |
| Configure browser MCP clients | `$session-workspace:workspace-browser-config` | Dry-run by default; writes only with `--apply` |
| Check harness activation/identity | `$session-workspace:harness-status` | Read-only |
| Diagnose harness setup | `$session-workspace:harness-doctor` | Read-only |

## Configuration Model

A project opts into workspace lifecycle by creating
`.agent-workspace/workspace.json` (`schema_version: 1` or `2`) describing:

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
- `browser` — optional Chrome DevTools session binding, pinned MCP package,
  loopback port, and portable derived profile
- `harness` — schema-v2-only explicit opt-in. `enabled: false` is inactive for
  new launches; a pane launched active still fails closed if the config is
  later disabled. `enabled: true` selects only `audit|enforce`, the immutable `strict-v1`
  profile, existing semantic role names, and bounded gate TTLs. It cannot
  inject scripts, regexes, shell fragments, or permission exceptions.

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
- The active strict-v1 harness fails closed on missing/invalid config,
  unknown pane identity, role/cwd drift, or a missing Python policy runtime.
  Its non-configurable floor keeps the orchestrator out of child writes,
  contains executor paths, makes reviewers read-only, and permits only
  selected installed helpers with exact reviewed argv/routing grammars.
- Codex renders an audit denial as an inert PreToolUse `systemMessage` because
  Codex 0.151 discards stderr from hooks that exit 0; Claude keeps the existing
  stderr audit line. This changes presentation only, never the policy decision.
- Codex 0.151 does not include an `exec_command` call's optional per-call
  `workdir` in the PreToolUse payload (the top-level `cwd` is the turn cwd),
  and non-shell read tools remain outside strict-v1 by design. Do not describe
  Codex `enforce` as complete path containment or recommend enabling it on that
  basis until Codex exposes per-call `workdir` or the plugin has a sound
  mitigation. Use `audit` while evaluating this platform limitation.
- `AGENTS.md` and project-local commands remain the contract for product,
  release, deployment, and domain-specific checks. The shared harness does
  not attempt to encode those project rules. Its normalized plan/audit TTLs
  are declarative values for that command layer, not evidence that a review
  occurred and not authorization for commit, push, deploy, or release.
