---
description: Overview of the session-workspace plugin — config-driven tmux workspace lifecycle
allowed-tools: Bash(bash:*)
---

## Contract Check

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace.sh" --contract`

## Instructions

Do not narrate or add a preamble.

1. This plugin replaces hand-maintained per-project `workspace.sh` launchers
   with one shared engine driven by a versioned `.agent-workspace/workspace.json`
   config. It is fully implemented: config load/validation, mutation-free
   planning, runtime argv/env construction, and tmux session/pane lifecycle
   (create, adopt, reconcile, stop, restart) are all live.
2. Report the Contract Check output above verbatim — it should read
   `session-workspace-cli 1`. If it does not, or errors, surface that
   verbatim; it means the install is broken.
3. Summarize the available lifecycle commands for the user:
   - `/session-workspace:workspace-doctor` — read-only dependency/config health check
   - `/session-workspace:workspace-plan` — dry-run plan (human + JSON), mutates nothing
   - `/session-workspace:workspace-start` — bring panes/sessions up (idempotent — healthy
     panes are never respawned)
   - `/session-workspace:workspace-status` — current lifecycle state, mutates nothing
   - `/session-workspace:workspace-stop` — tear panes/sessions down (destructive, requires
     `--confirmed`)
   - `/session-workspace:workspace-restart` — stop then start (destructive, `--confirmed`
     implicit)
   - `/session-workspace:workspace-reconcile` — dry-run by default; `--apply` repairs drifted
     managed state; use `--adopt --confirmed` to preview adoption and add
     `--apply` to perform it; `/session-workspace:workspace-start --adopt --confirmed` is the
     direct lifecycle alternative
   - `/session-workspace:workspace-install` — install or refresh the machine-wide `workspace`
     dispatcher on `PATH` (no config or tmux mutation)
   - `/session-workspace:workspace-browser-config` — preview or explicitly apply the project
     MCP entries derived from the optional browser block
   - `/session-workspace:harness-status` — read-only: is the opt-in strict-v1 harness active,
     and does this pane's engine identity match the validated plan
   - `/session-workspace:harness-doctor` — read-only harness health (config, activation, hook
     registration, python3, live identity)
   - `/session-workspace:workspace-orchestrator` — schema-v4 reviewed Git
     lifecycle (status/plan/dispatch/review/commit/push/deploy) across the
     configured executor/reviewer pairs; runs only from the configured
     orchestrator pane
4. Key safety gates worth knowing about, and relaying if the user hits them:
   - An unmanaged pane occupying a planned slot is never renamed or
     respawned — that slot fails with guidance rather than being silently
     repurposed.
   - A tmux session with the same configured name that this engine did not
     create is never touched (exact `=NAME` targeting, never a prefix
     match).
   - `stop` refuses without `--confirmed`; `restart` confirms its internal
     stop phase and accepts no separate `--confirmed` flag.
   - Secrets are delivered to exactly one pane's process environment via a
     private, single-use, mode-0600 file — never `send-keys`, never argv,
     never tmux session/pane metadata.
   - With `schema_version: 2`, `3`, or `4` and `harness.enabled: true`, a `PreToolUse`
     hook enforces the strict-v1 role floor (reviewer read-only, executor
     confined to its checkout, orchestrator kept out of child checkouts,
     master-only routing, exact trusted-helper provenance). Inactive
     configs are a true no-op for panes launched with an empty harness
     mode. Drift (a stale launcher mode, identity/config mismatch) fails
     closed in both modes — restart the pane's configured session via
     `/session-workspace:workspace-restart <session-id>` (this kills and
     recreates all of that session's configured panes).
   - Schema v3/v4 may add typed `harness.guards` for shared protected-file and
     child-chdir denials, generic lifecycle reminders, and bounded Stop
     health diagnostics. Guard changes require `workspace restart`.
   - Schema v4 may add a closed `orchestration` block (`reviewed-git-v1`):
     declarative targets binding a child cwd to its executor/reviewer pair,
     named remote, and distinct work/release refs — no commands, scripts,
     regexes, prompts, or gate bypasses. Drive it with
     `/session-workspace:workspace-orchestrator`; every Git mutation runs in
     the target's executor pane.
