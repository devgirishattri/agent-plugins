---
description: Bring up session-workspace sessions/panes/agents/services
argument-hint: "[TARGET|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed] | SESSION --pane NAME [--pane NAME...]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-start.sh" $ARGUMENTS
   ```

3. Real interface:
   - `TARGET|all`: optional `sessions[].id` filter. With no positional
     target, start uses `behavior.default_start_target` (default `all`);
     an explicit positional target always wins.
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--no-agents`: create/claim panes but do not launch Claude/Codex runtime
     panes. The pane is reported `[claimed]`, not healthy, and a later start
     without the flag launches its runtime.
   - `--no-services`: create/claim panes but do not launch service-role
     commands. The pane is reported `[claimed]`, not healthy, and a later
     start without the flag launches its command.
   - `--no-attach`: suppress post-start attach behavior regardless of
     `behavior.attach`.
   - `--adopt --confirmed`: allow occupied unmanaged panes to be claimed.
   - `SESSION --pane NAME` (repeatable): start only the named service panes
     (role `service`, such as the debug browser or a dev server) of one
     session. NAME is the pane name or the part after `<project.id>-`. The
     session is created if it is not running, with only those panes, and
     their declared commands run. Running panes are `[kept]`. `--pane` never
     attaches and cannot be combined with `--no-agents`, `--no-services` or
     `--adopt`.

4. Safety/behavior:
   - Start validates config, requires `jq` and `tmux`, and takes a project lock.
   - If the session-chat helper cannot resolve and
     `behavior.session_chat_helper.on_missing` is `fail`, start aborts
     non-zero before taking the lock or touching tmux. With `warn`, it
     continues with a warning and panes start without inter-pane messaging.
   - It creates only missing managed topology. A healthy managed pane is kept
     and not respawned.
   - It refuses to repurpose an occupied unmanaged pane unless `--adopt
     --confirmed` is present.
   - Without `--adopt --confirmed`, it also refuses a same-named tmux session
     with no managed marker. Preview session-level adoption with
     `$session-workspace:workspace-reconcile TARGET --adopt --confirmed`, then
     apply it with
     `$session-workspace:workspace-reconcile TARGET --apply --adopt --confirmed`.
     Direct adoption through this command is also supported with
     `workspace-start TARGET --adopt --confirmed` when a separate preview is
     not required.
   - It uses exact tmux session targets and managed markers to distinguish
     owned resources from user/foreign sessions.
   - On a fully successful run, attach is controlled by `behavior.attach`:
     `if_terminal` attaches only from an interactive terminal; `never` never
     attaches. `--no-attach` forces attach off. The command prints one
     `attach: ...` line for the decision.
   - With `--pane`, a dev-server pane (`port` plus `command`) whose port is
     already bound by another process is refused before launch, and the error
     names the holding PID, for example `service port occupied before launch:
     3001 (web) is held by pid 4242 (node)`. Relay it; do not retry on another
     port.
   - A pane with `idle_stop_minutes` prints an `[idle-stop]` line after it
     starts. A watcher stops the pane once nothing has used its port for that
     many minutes and records why in the pane's run record, which
     `workspace-status` shows. For a dev server, use means an inbound
     connection. For the browser, use means CDP commands, so an open
     chrome-devtools connection that only pings does not keep it up.
   - Secrets for authorized panes travel through a private 0600 single-use file
     path in the launch script; secret values are not placed in argv, tmux
     history, or session environment.
