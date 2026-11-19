# Peers template operating notes

`workspace-peers.json` is a schema-6 config with peer orchestrators. It declares
one orchestrator session (`development`, pane `sample-master`) and two checkouts
(`web` in `component-a`, `vue3` in `component-b`). It declares no executor, no
reviewer and no extra orchestrator. Copy it to `.agent-workspace/workspace.json`
and create `component-a` and `component-b` first. The engine does not clone
repositories.

Start the declared orchestrator with `workspace start development`. Only the
user starts and stops orchestrators. Start a second one with
`workspace start development-2`. `workspace start` never starts copies.
`peers.limits.orchestrators` is 4 and `peers.limits.workers_per_orchestrator`
is 6. Remove `limits` for no limit.

Each orchestrator starts its own workers:

```text
workspace start --checkout web --role executor --label auth
workspace start --checkout web --role reviewer --label auth
workspace show sample-web-executor-auth
workspace hide sample-web-executor-auth
workspace stop --worker sample-web-executor-auth --confirmed
```

`web` has `executors: "many"`, so several executors may run on it. `vue3` takes
the default `"one"`: a second executor gets `[held]` (exit 3). Another
orchestrator's worker also gives `[held]`. Workers start hidden. They run in a
window of the owner's tmux session sized by `SESSION_WORKSPACE_HIDDEN_SIZE`
(default `160x48`).

Notes:

- Every orchestrator is at the project root. Concurrent writes to shared root
  files are a user rule. Nothing in the engine coordinates them.
- The ownership rules are a guardrail on reviewed routes, not isolation. Do not
  set or unset launcher identity or `XDG_STATE_HOME` in an active pane.
- The engine writes `instances.json` under `${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/sample/`.
  Do not edit it.
- Replace `sample` and the `sleep 600` service commands with your own project id
  and dev server commands. Keep pane names prefixed with the project id.
- Upgrade both providers to 0.17.0 or later before using schema 6.

See `skills/session-workspace/references/environments.md`, "Peer orchestrators
(schema 6)".
