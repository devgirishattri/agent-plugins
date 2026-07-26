---
name: workspace-start
description: "Bring up session-workspace sessions/panes/agents/services. Use when the user asks to start, launch, or bring up the configured workspace."
---

# workspace-start

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-start.sh" $ARGUMENTS
```

Real flags:
- `TARGET|all`: optional `sessions[].id` filter. With no positional target,
  start uses `behavior.default_start_target` (default `all`); an explicit
  positional target always wins.
- `--config PATH`: use a specific workspace config instead of discovery.
- `--no-agents`: create/claim panes but do not launch Claude/Codex runtime
  panes. The pane is reported `[claimed]`, not healthy, and a later start
  without the flag launches its runtime.
- `--no-services`: create/claim panes but do not launch service-role commands.
  The pane is reported `[claimed]`, not healthy, and a later start without the
  flag launches its command.
- `--no-attach`: suppress post-start attach behavior regardless of
  `behavior.attach`.
- `--adopt --confirmed`: allow occupied unmanaged panes to be claimed.

Safety gates: start validates config, requires `jq` and `tmux`, and takes a
project lock. If the session-chat helper cannot resolve and
`behavior.session_chat_helper.on_missing` is `fail`, start aborts non-zero
before taking the lock or touching tmux; with `warn`, it continues with a
warning and panes start without inter-pane messaging. It creates only missing
managed topology and keeps healthy managed panes without respawning them. It
refuses to repurpose an occupied unmanaged pane unless `--adopt --confirmed`
is present.

A same-named tmux session with no managed marker is also refused without
`--adopt --confirmed`. Preview session-level adoption with
`$session-workspace:workspace-reconcile TARGET --adopt --confirmed`, then
apply it with
`$session-workspace:workspace-reconcile TARGET --apply --adopt --confirmed`.
Dry-run adoption mutates nothing.

On a fully successful run, attach is controlled by `behavior.attach`:
`if_terminal` attaches only from an interactive terminal; `never` never
attaches. `--no-attach` forces attach off. The command prints one
`attach: ...` line for the decision.

Authorized panes get secrets through a private 0600 single-use file path in
the launch script; the secret values are not placed in argv, tmux history, or
session environment.
