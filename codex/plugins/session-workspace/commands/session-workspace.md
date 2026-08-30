---
description: Overview of session-workspace lifecycle and the opt-in strict-v1 role-policy harness
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run the contract check and report its output verbatim:

   ```bash
   bash "$PLUGIN_ROOT/scripts/workspace.sh" --contract
   ```

   It should read `session-workspace-cli 1`. If it does not, or errors,
   surface that verbatim; it means the install is broken, not just
   incompatible.

3. This plugin replaces hand-maintained project-local `workspace.sh`
   launchers with one shared engine driven by a versioned
   `.agent-workspace/workspace.json` config. The engine is implemented: it
   validates config, renders dry-run plans, starts/stops/reconciles managed
   tmux sessions and panes, builds Claude/Codex argv, pins non-secret
   coordination env, and runs a read-only doctor.
   Schema-v2 projects may explicitly enable a shared, fail-closed `strict-v1`
   harness. Schema v1 remains unchanged and harness-inactive.

4. Summarize the available lifecycle commands for the user:
   - `$session-workspace:workspace-doctor [--config PATH] [--json]` - read-only dependency/config/runtime health check.
   - `$session-workspace:workspace-plan [TARGET|all] [--config PATH] [--json]` - mutation-free resolved topology plan.
   - `$session-workspace:workspace-start [TARGET|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]` - create missing managed topology and launch configured agents/services.
   - `$session-workspace:workspace-status [TARGET|all] [--config PATH] [--json]` - read-only tmux state report for planned panes.
   - `$session-workspace:workspace-stop [TARGET|all] [--config PATH] [--no-save] --confirmed [--all]` - destructive stop of marked sessions only.
   - `$session-workspace:workspace-restart [TARGET|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]` - stop then start the same target.
   - `$session-workspace:workspace-reconcile [TARGET|all] [--config PATH] [--apply] [--adopt --confirmed]` - dry-run or apply repairs; adoption requires confirmation.
   - `$session-workspace:workspace-browser-config [--config PATH] [--provider codex|claude|all] [--apply] [--json]` - preview or explicitly apply browser MCP entries.
   - `$session-workspace:harness-status [--config PATH] [--json]` - read-only harness activation, role, gate, and live identity status.
   - `$session-workspace:harness-doctor [--config PATH] [--json]` - read-only harness config/hook/runtime/identity validation.

5. Key safety gates:
   - All lifecycle verbs resolve and validate `.agent-workspace/workspace.json`
     before acting.
   - `workspace-plan`, `workspace-status`, and `workspace-doctor` are read-only.
   - A bare `workspace-start` uses `behavior.default_start_target` (default
     `all`) as its target; an explicit positional target always wins.
   - `workspace-start` attaches only after a fully successful run, controlled
     by `behavior.attach` (`if_terminal` or `never`). `--no-attach`
     suppresses attach regardless of config.
   - `--no-agents` and `--no-services` create and mark panes without launching
     their runtimes; those panes are reported `[claimed]` and a later start
     without the suppression flag launches them.
   - If the session-chat helper cannot resolve and
     `behavior.session_chat_helper.on_missing` is `fail`, `workspace-start`
     aborts before taking the lock or touching tmux; `warn` starts anyway with
     a warning.
   - `workspace-start`/`workspace-reconcile --apply` take a project lock and
     do not repurpose an occupied unmanaged pane unless `--adopt --confirmed`
     is present.
   - A same-named tmux session with no managed marker is also refused unless
     `--adopt --confirmed` is present. Preview session-level adoption with
     `$session-workspace:workspace-reconcile TARGET --adopt --confirmed`, then
     apply it with
     `$session-workspace:workspace-reconcile TARGET --apply --adopt --confirmed`;
     dry-run adoption mutates nothing.
   - `workspace-stop` requires `--confirmed` and kills only tmux sessions marked
     for the current `project.id`; exact-match tmux targets are used.
   - Secrets are not sent through tmux history, argv, or session env. Authorized
     panes receive a private 0600 single-use `KEY=VALUE` file; only that file
     path is embedded in the launch script, and the pane unlinks it after export.
   - Harness activation is explicit. A hook launched inactive (empty launcher
     mode) or without workspace identity is a true no-op. A pane launched
     active fails closed on invalid/disabled config or identity drift.
   - `strict-v1` is an immutable floor: orchestrator child writes are blocked,
     executors are cwd-contained, reviewers are read-only, and installed helper
     execution requires selected provenance plus an exact argv/routing grammar.
     Product/release/deployment rules remain project-local and in `AGENTS.md`.
     The normalized plan/audit TTLs are declarative inputs for that project
     command layer; strict-v1 does not create gate evidence or authorize
     commit, push, deploy, or release actions itself.
