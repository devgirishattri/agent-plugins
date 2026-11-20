---
name: workspace-start
description: "Bring up session-workspace sessions/panes/agents/services. Use when the user asks to start, launch, or bring up the configured workspace."
---

# workspace-start

When this skill is invoked, run the script below and report its result,
leading with the outcome.

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
- `SESSION-N [--no-attach]`: schema 6 with `peers`, the user only. Starts the
  orchestrator copy `SESSION-N` (N 2-999) of the declared orchestrator session
  without a config edit. `start` and `start all` never start copies. An
  orchestrator pane may not run it (`orchestrator.peer_lifecycle`).
- `--checkout ID --role executor|reviewer [--label L] [--show] [--owner PANE]`:
  schema 6 with `peers`. Starts a worker owned by the calling orchestrator on
  checkout `ID` (a declared environment id). `L` matches `^[a-z0-9][a-z0-9-]{0,23}$`.
  The worker starts hidden unless `--show`. `--owner` is for the user and is
  refused for an orchestrator. No positional target. Other configs give
  `ERROR: --checkout needs a schema-6 config with peers`.
- `SESSION --pane NAME` (repeatable): start only the named service panes
  (role `service`, such as the debug browser or a dev server) of one session,
  or executor/reviewer panes marked `"launch": "on_demand"`.
  NAME is the pane name or the part after `<project.id>-`. The session is
  created if it is not running, with only those panes, and their declared
  commands run. Running panes are `[kept]`. `--pane` never attaches and cannot
  be combined with `--no-agents`, `--no-services` or `--adopt`.

A full start leaves on-demand workers down and reports each as `[on-demand]
... start it with: workspace start SESSION --pane NAME`. `--pane` for a worker
prints `[ready]` only after its agent has shown its input line on every check
for a settle window. The window is `SESSION_WORKSPACE_AGENT_READY_SETTLE_MS`
milliseconds (default `1500`). `0` accepts the first input line. A choice, or a
screen without an input line, restarts the window. `[not ready]` means the
agent did not keep its input line in time, or shows a choice such as a folder
trust question. The pane is left running and the start exits non-zero. Relay
it, and do not send the worker a message until it is ready.

A peer worker start prints `worker: NAME (checkout C, role R, owner O, hidden)`,
then `[started]` and `[ready]`, exit 0. The same owner starting it again gives
`[kept]`, exit 0. `[held] ... — owner X` (exit 3) means another owner holds that
name, the checkout allows one executor (`executors: "one"`) and one runs, or the
name has unfinished work from another owner. `[limit]` (exit 1) means
`peers.limits.orchestrators` or `peers.limits.workers_per_orchestrator` is
reached. Relay the line. Do not retry with `--owner` or `--force`. See
`../session-workspace/references/environments.md` "Peer orchestrators (schema 6)".
`SESSION_WORKSPACE_HIDDEN_SIZE` (`COLSxROWS`, default `160x48`) sizes the hidden
worker window.

Safety gates:

- Start validates config, requires `jq` and `tmux`, and takes a project lock.
- Condition: the session-chat helper cannot resolve. The result depends on
  `behavior.session_chat_helper.on_missing`:
  - `fail`: start aborts non-zero before taking the lock or touching tmux.
  - `warn`: start continues with a warning. Panes start without inter-pane
    messaging.
- Start creates only missing managed topology. It keeps healthy managed panes
  without respawning them.
- Start refuses to repurpose an occupied unmanaged pane unless
  `--adopt --confirmed` is present.

A same-named tmux session with no managed marker is also refused without
`--adopt --confirmed`. Preview session-level adoption with
`/session-workspace:workspace-reconcile TARGET --adopt --confirmed`, then
apply it with
`/session-workspace:workspace-reconcile TARGET --apply --adopt --confirmed`.
Dry-run adoption mutates nothing.

On a fully successful run, attach is controlled by `behavior.attach`:
`if_terminal` attaches only from an interactive terminal; `never` never
attaches. `--no-attach` forces attach off. The command prints one
`attach: ...` line for the decision.

With `--pane`, a dev-server pane (`port` plus `command`) whose port is already
bound by another process is refused before launch. The error names the PID
holding it, for example `service port occupied before launch: 3001 (web) is
held by pid 4242 (node)`. Relay it and do not retry on another port. A pane
with `idle_stop_minutes` prints an `[idle-stop]` line after it starts; a
watcher then stops the pane once nothing has used its port for that many
minutes and records why. For a dev server, use means an inbound connection,
plus new pane output when the pane sets `"idle_activity": ["connections",
"output"]` (for a server that closes every connection after its response).
For the browser, use means CDP commands, so an open chrome-devtools
connection that only pings does not keep it up.

Authorized panes get secrets through a private 0600 single-use file path in
the launch script. The secret values are not placed in argv, tmux history, or
session environment.

For schema-v5 `--environment ID` selection, invoke the installed dispatcher as
`bash <PLUGIN_ROOT>/scripts/workspace.sh start --environment ID [flags]`
instead of the direct session script. Optional `--services` or `--development`
limits the group; no positional session or `--all` may accompany it. Read
`../session-workspace/references/environments.md` for scope and partial-failure
behavior. Existing stop confirmation requirements still apply.
