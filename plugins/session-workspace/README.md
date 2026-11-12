# session-workspace

Config-driven tmux workspace engine. One shared engine, driven by a
project-local `.agent-workspace/workspace.json`, replaces a hand-maintained
per-project `workspace.sh` launcher script.

## Problem it solves

A tmux-based multi-agent project typically needs a launcher script that
creates named sessions and panes, starts an orchestrator/executor/reviewer
agent in each with the right model/grants/environment, wires up shared
coordination stores (messages, tasks, context snapshots), and can tear
everything down again. When every project hand-rolls that script, the
scripts drift: one project's `stop` kills more than another's, one forgets
to pin an environment variable another relies on, one develops a bug the
others already fixed. `session-workspace` factors the ~85% that is identical
across projects into one engine, and expresses the ~15% that legitimately
differs — session/pane layout, per-role grants and models, which
coordination stores are exported, memory topology, secrets — as fields in a
versioned JSON config.

A project adopts the plugin by creating `.agent-workspace/workspace.json` —
that file alone is the adoption. All behavior lives in the plugin, normally
invoked through the machine-wide `workspace` dispatcher (or the provider
commands). A project-local `workspace.sh` shim is an optional, narrow legacy
bootstrap for running verbs without the dispatcher on PATH; it contains no
project logic and is not required — see "Bootstrap shim" below.

## Lifecycle verbs

All verbs are exposed as both a Claude command (`/session-workspace:workspace-doctor`, etc.)
and, in the Codex tree, a matching skill. From a shell they are reached as
`workspace <verb> [args...]` once the `install` verb has put the dispatcher on
your `PATH` (or `./workspace.sh <verb>` in a project carrying the older
per-project shim — see "The two entry points"). `workspace --contract` prints
the CLI contract string both entry points use for their compatibility check.

| Verb | Signature | Mutates tmux? | Purpose |
|---|---|---|---|
| `doctor` | `workspace-doctor [--config PATH] [--json]` | Never | Read-only health check: tooling versions, config validity, plugin dependency versions, pane cwds, secrets-file gates, state-dir writability, runtime resolution, coordination-base drift, session-chat helper resolution. |
| `plan` | `workspace-plan [TARGET\|all] [--config PATH] [--json] [--running]` | Never | Deterministic dry-run: resolves and prints exactly what `start` would do (sessions, panes, argv, env var *names*, grants) without touching tmux. `--running` adds a read-only `running` field per pane, the only form that reads tmux. |
| `start` | `workspace-start [TARGET\|all] [--config PATH] [--no-agents] [--no-services] [--no-attach] [--adopt --confirmed]`<br>`workspace-start SESSION --pane NAME [--pane NAME...] [--config PATH] [--no-attach]` | Yes | Creates only what is missing. A pane the engine already manages and is healthy is left alone (idempotent restart). `--pane` starts only the named service panes, or executor/reviewer panes marked `launch: "on_demand"`, which a full start leaves down; see "Single service panes on demand" and "On-demand workers". |
| `status` | `workspace-status [TARGET\|all] [--config PATH] [--json] [--pane NAME...]` | Never | Reports session/pane/role/runtime/model/cwd/process/health/running for every planned pane, one CDP health line per browser, and each idle-stop pane's watcher and last stop. |
| `restart` | `workspace-restart [TARGET\|all] [--config PATH] [--no-save] [--no-agents] [--no-services] [--no-attach]` | Yes | `stop --confirmed` followed by `start`, for the same target. Unlike the old launchers, `restart` accepts `--no-save`. |
| `reconcile` | `workspace-reconcile [TARGET\|all] [--config PATH] [--apply] [--adopt --confirmed]` | Only with `--apply` | Dry-run by default; `--apply` repairs missing/misnamed managed resources without respawning healthy panes. Use `--adopt --confirmed` to preview adoption, then add `--apply` to perform it; `start --adopt --confirmed` is the direct lifecycle alternative. |
| `stop` | `workspace-stop [TARGET\|all] [--config PATH] [--no-save] --confirmed [--all]`<br>`workspace-stop SESSION --pane NAME [--pane NAME...] [--config PATH] --confirmed [--force]` | Yes | Kills only tmux sessions carrying this project's managed marker. Refuses outright without `--confirmed`. `--pane` closes only the named service panes or on-demand workers and leaves the session running; a busy worker is left running unless `--force`. |
| `install` | `workspace-install [--target PATH] [--dry-run]` | Never (no tmux, no config) | Installs this plugin's `templates/workspace-dispatcher.sh` to `~/.local/bin/workspace` so `workspace <verb>` works machine-wide. Idempotent — an identical executable target reports `already current` and writes nothing, so it doubles as the refresh for that copy; an identical but non-executable target is chmod-repaired in place (no backup, no rewrite). Backs up only a differing existing target to `<target>.bak` before replacing it, verifies the result answers `--contract`, reports PATH membership, and prints (never writes) the `alias ws=workspace` line. |
| `browser-config` | `workspace-browser-config [--config PATH] [--provider codex\|claude\|all] [--apply] [--json]` | Never | Derives project-scoped Codex and Claude MCP entries from `browser`. Dry-run by default; `--apply` writes and backs up project config files, but never touches tmux, and refuses conflicting unmanaged entries. |
| `harness-status` | `harness-status [--config PATH] [--json] [--probe]` | Never | Read-only view of the opt-in harness (mode/profile/roles/gates), the strict-v1 role floor for this pane's role (every role outside a pane), the optional guard packs, and whether this pane's engine identity matches the validated plan. `--probe` decides this pane's built-in floor cases without running them and exits 1 on any unexpected decision. |
| `harness-doctor` | `harness-doctor [--config PATH] [--json]` | Never | Read-only checks for config, activation, all bundled hook registrations, schema-v3–v5 guards, `python3`, and live identity. Non-zero only on `ERROR`. |

`TARGET` is a `sessions[].id` from the config, or `all` (the default).
`--json` output on `plan`/`status`/`doctor` is produced from the same
computation as the human-readable form, so the two can never disagree.

`stop` also sends `Ctrl-C` to every managed, non-idle pane and waits
`SESSION_WORKSPACE_STOP_GRACE_SECONDS` (default `5`) before force-killing the
session, so an in-flight agent/service gets a chance to shut down cleanly.

### Single service panes on demand (`--pane`)

`workspace start SESSION --pane NAME` (repeatable) starts only the named
service panes of one session, such as the debug browser or one dev server,
without starting the rest of that session. If the session is not running it is
created with only those panes; their declared commands run as in a full start.
Panes that are already running are `[kept]`. A later full `workspace start
SESSION` fills in the other panes and keeps the running ones.
`workspace stop SESSION --pane NAME --confirmed` sends `Ctrl-C`, waits the
grace period, closes only that pane, and leaves the session and its other
panes running. Stopping the browser pane releases its port claim.

- **Selection.** `NAME` is a pane name, or the part after `<project.id>-`
  (`--pane browser` selects `example-browser`). Only role `service` panes and
  executor/reviewer panes marked `launch: "on_demand"` (see "On-demand
  workers") can be selected; other agent panes are refused. `--pane` needs one explicit session,
  never attaches, and is refused together with `--no-agents`,
  `--no-services`, `--adopt` (start) or `--all`, `--no-save` (stop).
  `split_tree` layouts are not built for a subset start and `retain_layout` is
  neither restored nor saved, so a subset never overwrites the saved layout.
- **Port safety.** Before it launches a dev-server pane (`port` plus
  `command`), `start --pane` refuses when the port is already bound by any
  other process and names the holder: `service port occupied before launch:
  3001 (web) is held by pid 4242 (node); nothing was started for it.` A pane
  this project already runs on that port is kept, not refused. The holder is
  found with `lsof`, or on Linux from `/proc`; a holder this user cannot
  inspect is reported with the `lsof` command to run. Full-session starts keep
  the schema-v5 check they had.
- **Idle stop.** A service pane with `idle_stop_minutes` (off by default) gets
  a watcher when it starts, reported as `[idle-stop] ... armed (watcher pid
  N)`. The watcher samples the pane's port every 30 seconds. For a dev
  server, idle means no inbound connection to its `port` (an open HMR or
  keep-alive connection is use; on Linux, so is a connection the server
  closed in the last 60 seconds). For the browser pane, idle means no CDP
  commands to `127.0.0.1:<browser.port>`: an open connection that only sends
  keepalive pings is idle (see below). After the whole window it runs
  `workspace stop SESSION --pane NAME` and records why, for example
  `idle: no CDP commands to 127.0.0.1:9326 for 30 minutes`. The watcher exits
  when its pane closes for any other reason, and a restarted pane is never
  stopped by an older watcher. A host where connections cannot be counted
  (no `/proc` socket table and no `lsof`) never stops a pane for idleness. The
  watcher needs `python3`.
- **Pane output (`idle_activity`).** Some dev servers close every connection
  right after the response: Laravel's `php artisan serve` answers each request
  with `Connection: close`. A 30-second sample then almost never finds a
  connection open, so steady use can look idle and the pane is stopped
  mid-use. On Linux the watcher also counts the `TIME_WAIT` socket each such
  request leaves on the server's port for 60 seconds, so there any short-lived
  connection that repeats at least once a minute (a health-check poller, too)
  keeps the pane up. macOS gives no reliable view of those (`lsof` never lists
  `TIME_WAIT`), so for such a server set `"idle_activity": ["connections",
  "output"]`: new output in the pane since the previous sample, such as the
  server's request log line, then counts as use too. The watcher compares
  tmux's history size and a hash of the pane's last lines at each sample;
  output from before the watcher armed does not count, and a sample at which
  the pane was resized only takes a new baseline. `status` shows `observing
  connections+output`, and the stop reason names both signals: `idle: no
  inbound connections to port 8000 and no new pane output for 30 minutes`. Any
  periodic output keeps the pane up, such as a file watcher's rebuild line, a
  health-check log or a ticking clock, which is why output is opt-in.
  `["output"]` alone ignores connections. It is refused on the browser pane,
  where Chrome writes to its pane on its own.
- **Run record.** Each selected pane has a record at
  `${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/<project.id>/panes/<pane>.json`
  with the watcher state, the last activity, and the last stop and its reason.
  The watcher and `workspace stop --pane` change it under one lock
  (`<pane>.json.lock`), and a watcher that finds a stop recorded for its pane
  exits instead of writing over it. `workspace status SESSION --pane NAME` shows it as `idle stop:` and
  `last stop:` lines.
- **Browser health line.** `workspace status` prints one line per browser
  pane before the per-session detail: `browser: example-browser
  http://127.0.0.1:9326 — up (Chrome/131.0)  cdp_clients=1`, or `down` with
  the `--pane` start command to run. Check it before a browser smoke.
- **Browser idleness and chrome-devtools.** chrome-devtools-mcp opens one
  DevTools websocket on its first tool call and holds it for its whole MCP
  session, sending a 6-byte ping about every 30 seconds. Its cheapest tool
  call sends about 150 bytes. So the watcher reads how many bytes each open
  connection has received from its client, and a sample counts as use when
  they sum to more than 32 bytes plus one byte per second since the previous
  sample. The bytes come from Linux `sock_diag` (the source of `ss -ti`) or
  macOS `nettop`. chrome-devtools-mcp reconnects by itself on its next call
  after `workspace start SESSION --pane browser`, so the master does not
  restart. Where per-socket bytes cannot be read, the browser falls back to
  counting connections, and an open chrome-devtools connection then keeps it
  up; `status` shows which with `observing traffic` or
  `observing connections`.
- **Harness.** Under strict-v1 the orchestrator may run exactly
  `workspace-start.sh SESSION --pane NAME... [--no-attach] [--config PATH]`
  and `workspace-stop.sh SESSION --pane NAME... --confirmed [--config PATH]`
  through the trusted helper path, for configured service panes of that
  session and the on-demand workers it coordinates. Executors and reviewers
  stay refused, by any route.

### On-demand workers (`launch: "on_demand"`)

In an active strict-v1 harness (schema 2-5, `harness.enabled: true`), an
executor or reviewer pane can be marked `"launch": "on_demand"`. A full
`workspace start` or `reconcile --apply` then leaves it down, reported as
`[on-demand] ... not started (launch on_demand); start it with: workspace
start development --pane example-web-executor`, and keeps it when it is
already running. The orchestrator starts the worker when it has a task for it
and closes it when the worker is idle:

```bash
workspace start development --pane web-executor
workspace stop development --pane web-executor --confirmed
```

- **Ready means ready to take a message.** `start --pane` for a worker
  returns once the agent draws its input line (Codex's `›`, Claude Code's
  `❯`), so a `session-chat` send right after it is not typed into a booting
  agent. A numbered choice on that line, such as a first-run folder trust
  question, is not ready. A worker that does not get there within
  `SESSION_WORKSPACE_AGENT_READY_TIMEOUT` seconds (default 120) is reported as
  `[not ready] ... the pane is left running`, and the start exits non-zero.
- **Closed only when idle.** `stop --pane` for a worker first checks that it
  is idle. It leaves the worker running, reports `[busy] ... left running:
  <reasons>` and exits 1 when a scheduler task assigned to it is still
  `assigned`, a task it reviews is in `review`, its session-chat inbox queue
  holds unread messages (the plan's messages store and both providers'
  default inboxes), or its screen shows a running turn (`esc to interrupt`).
  `--force` stops it anyway; it is the user's override, and the harness never
  lets an agent pane pass it. After a pane stops, the session's standard
  layout is applied again so the remaining panes share the window.
- **Where it applies.** Only the harness executor and reviewer roles, and
  never in a `split_tree` session, whose layout builds every pane at once
  (validation refuses both). A session that holds only on-demand workers is
  not created by a full start; `start --pane` creates it with the named
  worker. `plan` marks each worker `(on demand: ...)`, `status` adds a
  `launch: on demand` line with the start command while it is down, and the
  Stop health check does not count a down worker as missing.
- **The orchestrator's own session.** The orchestrator may start and stop the
  on-demand workers it coordinates (environment-scoped orchestrators: the
  workers of their own environment), and may stop or restart other sessions
  such as `services`. It may not stop or restart the session that holds its
  own pane, by any route (`stop` or `restart` of that session or `all`,
  `--all`, an environment stop or restart covering it, or any stop while
  `behavior.stop_scope` is `all`), under rule `orchestrator.self_stop`. That
  would end its own turn and leave the workers it started without a
  coordinator. `--pane` stops of workers and services stay allowed.

## Safety model

- **Managed markers.** Every session and pane the engine creates carries a
  `@session_workspace_*` tmux option (`@session_workspace_project`,
  `@session_workspace_session`, `@session_workspace_pane`,
  `@session_workspace_role`, `@session_workspace_runtime`). These markers,
  not a name match, are the sole authority for "did this engine create it."
- **`=NAME` exact-match targeting.** Every tmux existence/target check uses
  `=NAME` (tmux's exact-match session syntax), never a bare name, which tmux
  prefix-matches. This closes a defect present in the hand-maintained
  launchers, where `tmux has-session -t NAME` could silently match a
  same-prefixed session belonging to something else.
- **Never renaming an unmanaged pane implicitly.** If a planned pane slot is occupied
  by a pane the engine doesn't recognize (no matching marker), `start`
  leaves it completely untouched and reports the slot as failed with
  guidance, rather than repurposing it. Explicit adoption is available either
  through `workspace-start --adopt --confirmed` or through the recommended
  review-first flow: preview with `workspace-reconcile --adopt --confirmed`,
  then apply with the same command plus `--apply`.
- **Never adopting an unmanaged session implicitly.** A tmux session whose
  name matches the config but which carries no managed marker — the state
  every session predating this plugin is in — is refused the same way, and
  the refusal names the command that actually adopts it. With
  `--adopt --confirmed`, the session adoption plan (name, window, existing
  pane count, panes already carrying markers) is printed first. `start`
  adopts directly when given `--adopt --confirmed`; `reconcile` adopts only
  with `--apply`, so its default dry run changes nothing.
- **`--confirmed` gates.** `stop` refuses to run at all without
  `--confirmed`. `--adopt` (on `start` or `reconcile`) requires `--confirmed`
  too — adoption without review is never allowed.
- **Marker-scoped stop.** `stop` only ever kills a session that carries
  *this project's* marker value. A same-named session that isn't marked as
  ours is reported as skipped, never touched. `behavior.stop_scope` controls
  breadth: `"selected"` (default) stops only the target session(s);
  `"all"` (or the `--all` flag) widens to every session on the server
  carrying this project's marker, including ones the current config no
  longer lists.
- **Secrets never touch argv, `send-keys`, or tmux metadata — but they do
  transit one private file.** See "Secrets" below.
- **Project-scoped locking.** `start`, `reconcile --apply`, `stop` and the
  idle watcher's stops take one lock directory per `project.id` under the
  state directory, so two concurrent invocations can't race on the same
  splits or marker writes. Owning it takes an `O_EXCL` create of its `pid`
  file, not just a successful `mkdir` (uutils `mkdir` can report success to
  the process that lost a create race). A lock whose holder has died is taken
  over in place, under a `reclaim` marker and only while it still names the
  dead pid, and a release renames the directory aside before removing it, so
  a waiter never deletes a newer holder's lock. On-demand workers make an
  orchestrator take this lock far more often.

## Secrets

`secrets.env_file` (optional even when `secrets` exists — with no file,
allowlisted keys resolve from the launching process's environment only;
relative to `project.root` unless absolute) holds
`KEY=value` lines and is parsed literally — it is never `source`d or
`eval`'d, so a malicious value like `x=$(rm -rf ~)` stays inert text.
`workspace-doctor` and `validate-config` both gate it — but only when
`env_file` is actually set: it must then be mode `0600`, owned by the
current user, **not** a symlink, resolve inside the project root, and be
git-ignored, and a config that fails any of those gates fails validation
outright. With no `env_file`, no file metadata gate applies and allowlisted
keys come from the launching environment alone.

Delivery is not "secrets never touch disk" — it is a private, single-use,
0600 temp file whose **path** (never the value) is embedded into the
target pane's own launch script. That script is what actually reads the
file, using shell builtins (`read`/`export`, never `.`/`source`/`eval`),
exports each `KEY` into *that pane's own* process environment, and unlinks
the file immediately. The path travels as a plain argv element to `bash -c`
— it is never tmux-parsed, logged, or interpolated into a `send-keys` call
(the historical bug this design specifically fixes: a secret token
interpolated into `send-keys` lands in shell history and pane scrollback).
`tmux set-environment -h` (hidden session env) is deliberately **not** used
for secrets, because hidden variables are documented to never propagate
into the environment of new processes — only regular (non-secret) pinned
env uses that mechanism (see `env.groups.*.pin_to_session` below).

`secrets.allow` is the list of keys a pane may request; `secrets.visible_to_roles`
is the global ceiling on which *roles* receive any secret at all — a role
absent from that list (or every role, when the list is omitted or empty)
gets nothing regardless of `allow`. Each `allow` entry is either a key string,
which every ceiling role receives, or a closed `{"key": "KEY", "roles": [...]}`
object, which narrows that key to the listed roles *within* the ceiling (a
listed role outside the ceiling, or an empty `roles`, grants nothing). Keys
are unique and case-sensitive across both forms; unknown roles are rejected.
`workspace-plan` shows each pane's `secret_keys` and the per-role key map,
names only. `secrets.on_missing` (`"warn"` or `"fail"`) controls what happens
when a key the pane's role is entitled to isn't present in the file or the caller's environment
(the caller's environment is checked first, then `env_file`; a value in the
caller's environment wins): `"fail"` aborts
that pane's launch outright; `"warn"` starts the pane without it.

## Harness, guard packs, and reviewed orchestration (opt-in, schemas v2–v5)

`schema_version: 2` adds one optional, typed `harness` block that turns the
workspace into a fail-closed multi-agent harness: one **orchestrator** pane,
and per child checkout one **executor** / **reviewer** pair, with an
executable role policy enforced by a `PreToolUse` hook on both providers.
Everything else in the config is unchanged between v1 and v2; an existing
v1 config keeps working with no edits (a v1 config with a `harness` key is
rejected).

`schema_version: 3` is v2 plus optional, declarative `harness.guards`.
Without `guards`, a v3 normalized plan and policy decision are byte-identical
to v2. Guard packs centralize reusable project hooks without accepting a
script, command, regex, or permission exception.

`schema_version: 4` is v3 plus an optional top-level `orchestration` block
(reviewed Git orchestration). v4 harness and guards behave exactly like v3,
and a v4 config without `orchestration` produces a byte-identical normalized
plan and policy decision to v3. Like guards, orchestration is closed, typed
data: it names coordinates (targets, remotes, branches) and never accepts a
command, script, regex, prompt fragment, custom gate, or permission bypass.

**Activation is explicit.** The hook is a true no-op — no Python is even
spawned — for: a session with no `SESSION_WORKSPACE_CONFIG` (not launched
by this engine), a schema-v1 config, a v2–v5 config with no `harness` block,
and `harness.enabled: false` (which must then carry no `mode`/`profile`/
`roles`/`gates`/`guards` siblings) — provided the pane's launcher mode
(`SESSION_WORKSPACE_HARNESS_MODE`) is empty. A pane launched while the
harness was `audit`/`enforce` still carries that mode after the config is
disabled; that is drift, and it intentionally blocks until the pane is
restarted. Only `enabled: true` with `mode` (`audit` | `enforce`),
`profile: "strict-v1"`, `roles`, and `gates` activates it.

### Per-pane engine identity

Every pane the engine launches receives seven base **engine-owned** variables
(the six identity values plus `SESSION_WORKSPACE_READ_PATHS_JSON`, exported
empty when the pane has no read paths); a guarded schema-v3–v5 launch also
receives `SESSION_WORKSPACE_GUARDS_JSON`, and a schema-v5 config with
`environments` adds `SESSION_WORKSPACE_SCOPE_JSON`. They live in the pane's own process environment — never mirrored into the tmux
session env, never settable from `env.groups`/`pane_name_aliases` (both are
validation errors) — and `workspace-plan` lists their names:

| Variable | Value |
|---|---|
| `SESSION_WORKSPACE_CONFIG` | absolute, canonical path of the config the pane was launched from |
| `SESSION_WORKSPACE_PROJECT_ROOT` | canonical project root |
| `SESSION_WORKSPACE_PANE_NAME` | the pane's configured name |
| `SESSION_WORKSPACE_ROLE` | the pane's configured role name |
| `SESSION_WORKSPACE_PANE_CWD` | the pane's resolved cwd |
| `SESSION_WORKSPACE_HARNESS_MODE` | `audit` or `enforce` when active; empty for v1, no `harness`, or `enabled: false` |
| `SESSION_WORKSPACE_GUARDS_JSON` | canonical guard JSON for a guarded v3–v5 launch; absent for v1/v2 and v3–v5 without guards |
| `SESSION_WORKSPACE_READ_PATHS_JSON` | canonical `[{path, kind}]` for a reviewer or executor with `read_paths`; exported empty for every other pane so an inherited value is cleared |
| `SESSION_WORKSPACE_SCOPE_JSON` | canonical environment scope for a pane of a schema-v5 config with `environments`; absent otherwise |

The policy cross-checks this identity against the validated config on every
gated tool call and **fails closed** on any disagreement: unknown pane, role
or cwd mismatch, project-root mismatch, `SESSION_CHAT_PANE_NAME` /
`KNOWLEDGE_PANE_NAME` disagreeing with the engine name, a config that no
longer validates, or config drift (harness enabled/disabled/mode-changed
after launch). Integrity failures block in **both** modes — `audit` only
softens policy denials. The remedy for drift is always restarting the
configured session that contains the pane
(`workspace restart <session-id>` / `/session-workspace:workspace-restart
<session-id>`) — which kills and recreates ALL of that session's configured
panes, not just the drifted one — never editing the variables by hand.

### Schema-v3 shared guards

All packs are optional and additive. Policy denials follow `harness.mode`;
health/lifecycle packs only add non-blocking context. Today they provide:

- `protected_files`: for the orchestrator Edit/Write/NotebookEdit/apply-patch
  family within the project root, deny `.env`, `.env.*`, common JS/PHP lockfiles,
  `google-services.json`, and generic service-account/Firebase JSON names.
  `extra_basenames` adds exact basenames only; it cannot remove defaults.
- `orchestrator.deny_child_chdir`: deny `cd`/`chdir`/`pushd` and reviewed
  `env -C`/`--chdir` hops into a configured child checkout. `git -C` and
  `make -C` remain command options, not process-directory changes.
- `lifecycle.session_reminder` and `.prompt_reminder`: generic role/routing
  context on SessionStart and UserPromptSubmit; no project command names.
- `workspace_health` runs only in the configured orchestrator pane.
  `warn_root_dirty`: at Stop, report root working-tree
  changes; `.warn_missing_panes`: report missing **non-optional**, non-service
  agent panes; `.branch_ahead`: for executor child roots with both configured
  local branches, report the neutral fact that `release` is ahead of `base`.
  In a schema-v5 config with `environments`, the orchestrator panes whose cwd
  is the project root (and the unbound root orchestrator) report it; a
  coordinator confined to a control directory does not. Before 0.12.13 the
  Stop wrapper accepted only schema 3 or 4, so a v5 config's
  `workspace_health` warnings never appeared.

The lifecycle/health wrappers exit silently before jq/Python when the guarded
v3–v5 launcher identity is absent or the feature is off. Lifecycle reminders use
event-specific `hookSpecificOutput.additionalContext` JSON on both providers.
Stop checks are bounded, skip non-git roots and absent refs, and never block
stopping.

### Schema-v4 reviewed Git orchestration

`orchestration` (schema v4 or v5, requires `harness.enabled: true` with
`profile: strict-v1` and `stores.pin` including `messages` + `scheduler`)
declares the fixed `reviewed-git-v1` profile plus one or more targets:

```json
"orchestration": {
  "enabled": true,
  "profile": "reviewed-git-v1",
  "targets": [
    {
      "id": "component",
      "cwd": "component-a",
      "remote": "origin",
      "work_branch": "main",
      "release_branch": "production",
      "deploy": { "strategy": "merge-no-ff-v1", "align_work_after_release": true }
    }
  ]
}
```

Validation is closed and cross-checked: each target `id` is a unique
restricted identifier; `cwd` must exactly equal one configured executor pane
cwd (which the harness already pairs with exactly one reviewer), resolve to an
existing distinct child inside the project root, and be unique after physical
path resolution; `remote` is a safe literal remote name (never a URL); the
work/release refs are distinct safe literal Git refs; `deploy.strategy` is the
const `merge-no-ff-v1`; `align_work_after_release` (default `false`) can
authorize only a post-release `--ff-only` alignment of the work branch.

The `workspace-orchestrator` skill (Claude
`/session-workspace:workspace-orchestrator`, Codex
`$session-workspace:workspace-orchestrator` — the same contract on both
providers) consumes the normalized `workspace-plan --json` targets (resolved
executor/reviewer pane names and absolute cwd) and drives the invariant
lifecycle: status → written plan → independent reviewer approval → explicit
user confirmation → scheduler-tracked executor assignment → independent audit
→ separately authorized commit → push → deploy. Plan approval is a correlated
reviewer reply carrying an explicit `APPROVE` token; audit approval is a
reviewer-authored scheduler closing note (or correlated reply) with an
explicit `APPROVE` token — a `done` status alone proves closure, not a clean
verdict. Freshness comes from the existing `harness.gates`
`plan_review_ttl_minutes` / `audit_ttl_minutes`. The orchestrator pane
coordinates only: every Git mutation runs in the target's executor pane under
a fixed Git floor (fetch/status reads, commit on work, normal pushes of the
configured work/release refs, the reviewed `--no-ff` work-to-release merge,
optional `--ff-only` alignment — never a force push, leading `+`, ref
deletion, history rewrite, or `checkout -B` on release). That Git floor is
the workflow's contract, which the skill follows; the strict-v1 hook does not
check it. The hook keeps the orchestrator from pushing or mutating a child
checkout, but an executor's `git push --force`, `git reset --hard` or
`git checkout -B` is not refused, so protect release branches on the remote
where a force push must be impossible. Deploy is gated by a
six-check executor preflight: both branches exist locally and at the remote,
release-to-work has commits to ship, work-to-release is empty, both local
branches exactly equal their remote refs, and the tree is clean. The pinned
scheduler ledger and session-chat archive are the canonical evidence — the
skill writes no parallel evidence log — and the selftest / prompt-preview
workflows are strictly read-only. User confirmations (dispatch, commit, push,
deploy) are conversational gates: the skill reports them honestly and never
claims the harness enforces them. Product-specific build/test requirements
stay in the target repository's `AGENTS.md`. Migrating from v3 is one config
edit: set `schema_version: 4` (behavior unchanged), then add `orchestration`
when ready. Adding or editing `orchestration` does not itself change launcher
identity or require a restart — it invalidates any orchestration
evidence collected under the previous coordinates, so in-flight workflows
restart at plan review. A session restart
(`workspace restart <session-id>`, which kills and recreates every
configured pane in that session) is required for identity/launcher-bearing
changes — for example `project.root`, a pane's name, role, cwd, or runtime,
`harness` mode/roles, or `harness.guards` — because those are baked into the
engine-owned launch identity the policy cross-checks.

### The strict-v1 floor (immutable, not configurable)

Configuration selects *which* panes hold each role; it cannot add scripts,
regexes, shell fragments, commands, or permission exceptions. `harness-status`
prints a summary of this floor on its `floor (strict-v1, not configurable):`
lines, generated from `ROLE_FLOOR` and the enforcement tables in
`harness-policy.py` (`--floor-json`), and `harness-status --probe` decides
each role's built-in floor cases through the hook's own code path
(`--probe-json`). Its `optional guard packs:` line lists only
`harness.guards`, which adds to the floor; an empty packs line never means a
role floor is off. The floor:

- **Draft staging (reviewer, executor, environment-scoped coordinator)** —
  from 0.7.1 the only message-store write is the pane's own drafts
  directory, `<messages grant>/drafts/<pane-name>/<name>.md|.txt` (the grant
  is normally `.tmp/messages` and comes from the workspace plan, never
  inherited environment overrides). Native create/edit/delete only; shell
  writes and `rm` stay denied, so Claude panes (no native delete tool)
  leave delivered drafts in place. The target's parent must canonicalise to
  exactly that directory; names not starting with an ASCII letter or digit (or using other than letters, digits, `.`, `_`, `-`; stem at most 128), symlinked directories, hardlinked or
  non-regular targets, moves, other panes' drafts, the store top level,
  delivered dispatch files, queue/archive/ledger state, and patches touching
  any other path are denied. A pane whose role has no `messages` grant gets
  no staging exception (fail closed); an executor keeps its ordinary checkout
  write authority, which is not a substitute staging contract. The root
  orchestrator's existing authority over store and transport files is
  unchanged. Arbitrary executor shell commands (anything outside the single
  literal read grammar) and confined-coordinator shell commands may not name
  a granted messages store, even one nested inside their cwd.
- **Message reads (0.10.0)** — reviewer and executor shell reads of any
  messages store or provider inbox follow "Message store access" below.
- **Reviewer** — native edit/write/patch/notebook tools are limited to draft
  staging above. Shell is
  default-deny, with two carve-outs: (a) exact read forms (0.12.11, see
  "Reviewer exact read forms" below): listed read programs (`cat head tail
  wc ls stat file diff grep rg find sort ...`, `sed -n 'N[,M]p'` and
  listed read-only `git` forms) joined only by `|`, `||`, `&&` or `;`,
  whose path operands — including bare `.`/`..`, path option values such
  as `git config --file FILE`, and git revision words — resolve through symlinks
  inside its own checkout, the coordination stores the plan grants it (a
  messages store or either provider's inbox only as scoped by "Message
  store access" below), or the *selected version* directory of an installed
  plugin — no redirection, substitution, double quotes, backslashes,
  unquoted `^`/`~`/globs, `cd`, wrappers or unlisted assignment prefixes,
  path-written executables, `awk`/`perl`, `tail -f`, `find -exec`, or reads
  of sibling checkouts via `../`; (b) trusted
  coordination helpers (below): session-chat send/dispatch/reply to the
  orchestrator only, scheduler `task-done`/`task-block` (never `--force`,
  never `task-new`/`task-assign`), context save/share/load/list/search/diff,
  read-only knowledge recall/search/graph/lint/doctor and the docs
  validators. Never memory/docs writes.
- **Executor** — edit targets must resolve (through symlinks) inside its
  configured pane cwd. Arbitrary shell stays available for builds/tests/git
  inside the checkout, but every path-like operand must resolve inside that
  cwd (absolute, `../`, bare `..`, quoted paths with spaces, `-C`/`--chdir`
  values, and symlink escapes alike) — the fixed `/dev/null` sink/source is
  the only exempt operand; `cd`/`chdir`/`pushd`/`popd` are
  tracked across a composed command so later operands resolve against the
  directory the shell would actually be in, and a `cd` whose target leaves
  the cwd (or `cd -`, a bare `cd`, `pushd` with no operand) is refused;
  operands that only exist after a shell expansion (`"$TARGET"`, backticks,
  unquoted globs/braces) fail closed; from 0.13.1 an unquoted word that is
  exactly `{}` (the `find -exec` placeholder) is decided like `'{}'` when it
  is an argument of an ordinary command, because no shell expands it, while a
  `{}` that can start a command (first word, after `then`, `else`, `do`,
  `time`, an assignment or a redirection) stays refused, because zsh reads it
  there as an empty `{ }` group; redirection targets (`> file`,
  `>> "escape link"`, `2> /tmp/x`, `< ../x`) are path operands too;
  attached `-C..`/`-Cdir` and `--chdir=` values are resolved; from 0.7.4,
  paths attached to short options (`-f/x`, `-o/x`, `-t/x`, clustered
  `-uo/x`) and every operand after a standalone `--` (even one starting with
  `-`) are path operands too, for reviewer reads, executor containment, and
  orchestrator child-write checks alike (`grep`/`rg`/`sort` know which
  letters take a pattern versus a file, so `grep -e/api/` stays a pattern;
  reviewers may never use `sort -o`/`-T` or any abbreviation of
  `--output`/`--temporary-directory`/`--compress-program`; from 0.12.7 they
  may not give `uniq` an output operand (`uniq in out`, or BSD's
  `uniq in -c`), run `file -C`, set the clock with `date -s`/`--set` or a
  non-`+FORMAT` operand, load operands from a list with `file -f` or
  `shasum`/`cksum -c`, or run `git reflog` other than bare,
  `show`, `list` or `exists`, so `expire`, `delete` and `drop` are refused); redirection
  targets are checked against the shell's cwd and can never be consumed as a
  data value (`grep -e > out`); a bare operand
  that names an existing entry (a planted symlink) is canonicalized;
  `xargs`, inline code (`bash -c`, `python -c`, `node -e`, `eval`; from
  0.12.7 also attached and clustered forms such as `python3 -c"..."`,
  `python3 -Bc`, `perl -lne`, `ruby -e'...'`, `php -nr`, `node -p`,
  `--eval=`/`--print=`, `perl -E`, `php -B/-R/-E`, a `data:` URL module
  load, and versioned binaries such as `python3.12`; from 0.12.8 also a
  program on stdin, from a pipe, heredoc, here-string, `<` redirect or `-`
  (`echo code | python3`, `bash <<EOF`, `node <<<'...'`, `bash -s`), the same
  forms behind a launch prefix (`timeout`, `nice`, `stdbuf`, `ionice`,
  `setsid`, `taskset`, `chrt`, shell keywords such as `then`/`do`/`!`, and
  `find -exec`), and a command on the next line of a multi-line command), and any
  sandbox/approval-escape flag are refused. Outbound
  coordination may only target
  the orchestrator; direct `tmux send-keys`/`paste-buffer`/... and copied or
  relative session-chat helpers are refused as routing bypasses. Executors
  additionally get `task-review` and `memory-remember` (including the
  read-only `--list --dismissed`, from 0.7.2); reviewers get neither.
  `memory-write` — including the knowledge 0.3.30 `dismiss`/`restore` verbs —
  stays orchestrator-only.
- **Orchestrator** — may not edit or run mutating commands against any
  child checkout root (read-only commands and `git` reads against a child
  are fine), and never runs `git push` — including behind `env`, `command`,
  `exec`, `nohup`, or an assignment prefix (pushes go through the owning
  executor and the project's own release gate); `cd child && ...`,
  `git -Cchild`, `make -Cchild`, `env --chdir=child` and write
  redirections into a child count as child mutations; its own root, the
  config,
  and files outside the workspace are not otherwise gated. Its shell is
  otherwise free. It owns `task-new`/`task-assign`
  (only to configured executor/reviewer panes), `tasks-clean`,
  `messages-clean`, memory/docs writes, and every workspace mutator,
  including the single-pane `workspace-start.sh SESSION --pane NAME` and
  `workspace-stop.sh SESSION --pane NAME --confirmed` forms (configured
  service panes of that session, and the on-demand workers it coordinates;
  never `--force`). It may not stop or restart the session that holds its
  own pane, by any route (rule `orchestrator.self_stop`; see "On-demand
  workers"). Executors and reviewers are refused
  the lifecycle verbs (`start`, `stop`, `restart`, `reconcile`, `install`,
  `browser-config`) by any route, including the `workspace` dispatcher on
  `PATH`, under rule `coordination.write`.
- **Unknown tools are allowed** for every role (`Read`, `Grep`, `Glob`,
  `WebFetch`, ...). Classification is by tool *name*, never by the shape of
  the payload, so the plugin is a floor, not a tool allowlist.
- **One literal wrapper grammar for any role.** The launch wrappers
  `parse_wrappers` recognizes, and the complete set of options it accepts:
  `NAME=value` prefixes (any number, at any hop); `env` with
  `-i`/`--ignore-environment`, `-u NAME`/`--unset NAME`/`--unset=NAME` (a
  literal variable name), `-C DIR`/`-CDIR`/`--chdir DIR`/`--chdir=DIR` (a
  literal directory; nested `env -C` hops compose in order, each resolved
  through symlinks against the previous hop and checked, while a repeated
  `-C`/`--chdir` within one `env` behaves like `env` itself — the last
  value wins, against that `env`'s starting cwd — with every given value
  still checked), `NAME=value` assignments, and a terminating `--`;
  `command CMD` (`command -v`/`-V` is a lookup query, not a wrapper);
  `builtin CMD`; and bare `exec CMD`, `nohup CMD`, `time CMD` with no
  options. An unsupported, missing, or dynamic wrapper option — `exec -a`/
  `-l`/`-c`, `nohup --`, `time -o`/`-p`, `/usr/bin/time -o`,
  `env -S`/`--split-string=` (a re-parsed argv), `env -u` without a name,
  `env --unset=` with an empty or invalid name, `env --default-signal`,
  `command -p`, `builtin -x` — is refused (`shell.wrapper`), and the
  privilege wrappers `sudo`, `doas`, `su`, `runuser`, `pkexec` at any hop
  (`env sudo`, `command doas`, `FOO=1 sudo`, a later segment) are refused
  outright (`shell.privilege`) — a privileged or re-parsed argv is never
  modelled.
- **No permission-widening escape hatch for any role**: a shell command
  carrying `--dangerously-bypass-approvals-and-sandbox`,
  `--dangerously-bypass-hook-trust`, `--dangerously-skip-permissions`, or
  `--permission-mode bypassPermissions` (a nested agent launch) is refused
  everywhere, matching the engine's own refusal of those flags in
  `runtimes.*.args`.
- **Read roots are exact, and scoped by surface.** A *reviewer's* shell
  operands, and *trusted-helper* operands for any child role (a dispatch
  prompt file, `--store`, a context snapshot), may resolve inside: the
  pane's own cwd; the coordination stores the plan *grants* that pane
  (`roles.<r>.grants`, i.e. the same directories it receives as
  `--add-dir`); `~/.claude/messages` and `~/.codex/messages` (helper
  operands only: shell reads of any messages store or provider inbox follow
  "Message store access" below); and the
  *selected version* directory of an installed plugin (never another
  version, never an unselected plugin). An *executor's* arbitrary shell is
  narrower still: every operand must resolve inside its pane cwd alone
  (`/dev/null` excepted).
  A reviewer's *shell* operands and tool `cwd`/`workdir` (never helper
  operands) may additionally resolve inside that pane's `read_paths` (see
  "Reviewer read paths" below). An executor's `read_paths` admit only
  single literal read commands under the reviewer read grammar (see
  "Executor read paths").
  Inherited `SESSION_*_HOME` / `SESSION_CHAT_TARGET_MESSAGES_DIR` values
  and the rest of a marketplace cache are deliberately not trusted. A plain `memory-search.sh --recall`
  without `--store` still works for a pane without a memory grant (the
  script resolves its own store); only an explicit `--store` outside the
  granted roots is refused.
- **Child routing is master-only.** Children address only the orchestrator;
  the orchestrator addresses only its configured executor/reviewer panes;
  `broadcast-message.sh` has no topology-bound form and is not allowed in
  strict-v1.

### Message store access

From session-workspace 0.10.0 (paired with session-chat 0.17.13), reviewers
and executors can read complete file dispatches; before this, an executor
could not read a task body past the inline cap, and a reviewer could read the
whole store.

- **How to read.** In `auto` the session-chat incoming hook prints the
  literal `Full task read command: cat '<absolute-path>'` before the inline
  body; run it verbatim. The inline copy is capped by
  `SESSION_CHAT_DISPATCH_INLINE_MAX` (default 6000 characters) and the hook's
  total context cap; the file is not, so never split a task into parts to
  fit. `assist` shows no body and gives the same command only for use after
  the local user approves; `notify` offers no command.
- **What is readable** (`coordination.message_read`, allow): a file directly
  in this pane's plan `messages` grant named
  `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md`, where the name splits into
  exactly one pair of validated plan pane names (every `-to-` split is tried,
  including overlapping ones) with this pane as sender or recipient; the file
  is private (no group/other bits), owned by this user, regular, single-link,
  and reached with no symlink component and no `..`. Existing own drafts
  (`drafts/<own-pane>/<name>.md|.txt`) are readable too.
- **Grammar.** Only the existing single literal non-`git` read grammar
  (`cat`, `head`, `tail`, `wc`, `rg --no-config`, ...): no pipes,
  redirection, expansion, globs, `sed`/`awk`/`perl`, or symlink-follow
  options. A piped or copied read of an own message falls back to the
  executor floor and is refused there; a reviewer's is refused by its exact
  read forms (`coordination.message_read`, 0.12.11). NUL-separated file-list options
  (`sort`/`du`/`wc --files0-from` and every abbreviation, `find
  -files0-from`) are refused in the restricted read grammar for every
  reviewer and executor read (`reviewer.file_list`; `coordination.message_read`
  when the list is a message): this closes a pre-existing reviewer bypass
  where a list file named paths the policy never saw. An executor's general
  shell floor can still pass an in-checkout list file (arbitrary-shell
  residual).
- **What is denied** (`coordination.message_read`, deny): other panes'
  messages and drafts, off-plan or ambiguous senders, files involving removed
  panes, queue/archive/ledger state, subdirectories, `git` operands in any
  store, and ungranted provider inboxes (`~/.claude/messages`,
  `~/.codex/messages`). Every plan messages grant is guarded, so a pane
  without its own grant cannot borrow checkout access to a store nested in
  its cwd. Identity and roots come from the validated plan only; inherited
  `SESSION_CHAT_TARGET_MESSAGES_DIR` or `SESSION_CHAT_PANE_NAME` cannot
  widen them.
- **Traversal** (`coordination.message_traversal`, deny): recursive reads
  that would enter a store from an ancestor directory — `rg`, `find`, `du`,
  recursive `grep` (`-r`, `-R`, `-d`), `ls -R`, including an implicit cwd —
  and child tool workdirs inside a store. Name explicit subdirectories
  outside the store; glob exclusions do not grant an exception. Executor
  operands resolve against the effective tool workdir.
- **Unchanged.** Own-draft native writes, send routing, incoming-mode
  consent, and coordinator (orchestrator) behavior.
- **Known limits.** strict-v1 does not gate Claude's native `Read`; operand
  checks cannot see what an arbitrary program opens (an executor's general
  shell floor can still recurse through `cp -r` or a script); the checks are
  not atomic against same-uid filesystem swaps.
- **Rollout.** No schema or store migration. Update session-chat and
  session-workspace, then restart affected panes. Rollback restores the
  executor read failure and the broader reviewer access.

### Reviewer read paths

A reviewer keeps its child checkout as `cwd`, and can be granted extra
**shell reads** per pane:

```json
{ "name": "component-a-review", "role": "reviewer", "cwd": "component-a",
  "read_paths": ["docs", "AGENTS.md", "/Users/<you>/src/<external-repo>"] }
```

- Relative entries resolve against the project root and must stay inside it;
  absolute entries must already be canonical (for example `/private/tmp/...`,
  not `/tmp/...` on macOS) and may name an external repository.
- A file grants that exact file only (not its parent or siblings); a
  directory grants its descendants.
- Validation (fatal for the whole config): at most 16 entries; literal paths
  only (no `$`, backticks, globs, leading `-`/`~`, control characters, `..`);
  no duplicate or nested entries; no overlap in either direction with
  `stores.base`, `stores.overrides.*`, `stores.memory.root`,
  `secrets.env_file`, or the Claude/Codex homes; not `$HOME` or any ancestor
  of it; in a v5 config, not inside another environment's cwd or panes.
- Disk state (per pane): a missing path, a non-file/non-directory, or a path
  with a symlink component is reported as `kind: "unavailable"` with an
  `error` in `workspace-plan`. `start`, `restart` (checked before it stops
  anything) and reconcile/adopt refuse to launch that session; a running
  pane is blocked with `identity.read_paths` in both modes until the
  path is restored. Other panes, `stop`, and `status` are unaffected.
- The reviewer policy also refuses recursive symlink-follow options (`rg
  -L/--follow`, `grep -R/-S/--dereference-recursive/--dereference-files`,
  `find -L/-follow`, `du -L`, `ls -L`, `diff -r`) and `diff` with a directory
  operand, because traversal below a checked operand cannot be verified.
- Relative operands resolve against the effective tool `cwd`/`workdir`;
  conflicting `cwd`/`workdir` or a non-directory workdir is refused, and
  trusted helpers must run from the configured pane cwd.
- **Scope of the grant.** `read_paths` never becomes `--add-dir`, a write
  permission, or a helper/knowledge-store grant, and the agent argv is
  unchanged. strict-v1 does not gate native `Read`/`Grep`/`Glob` tools, so
  Claude's own permission layer still decides native reads outside the cwd
  (a prompt, or a refusal under `permission_mode: dontAsk`). The hook check
  is not atomic against a same-uid process swapping the filesystem between
  the check and the read.

### Reviewer exact read forms (0.12.11)

Every reviewer shell command passes one exact-form grammar before any shell
sees it. Per-tool option parsing kept producing new bypasses (option values
read as files, BSD and GNU disagreeing on `--`, zsh globbing), so the floor
now admits only forms it lists and refuses everything else. The tables are
`EXACT_FORMS` and `EXACT_GIT` in `harness-policy.py`; `--floor-json` counts
them, and `workspace.json` cannot add to them.

- **Words.** Each word is plain (letters, digits and `_ . / : , + = @ % -`)
  or exactly one single-quoted run with nothing attached. The one join
  allowed is the POSIX `'it'\''s'` idiom that session-chat prints for a
  path holding an apostrophe; it is literal in bash and zsh alike. `^`, `~`, `*`,
  `?`, brackets, braces, spaces and `$` appear only inside single quotes
  (zsh `EXTENDED_GLOB` reads `^x` and `a~b` as globs; a leading `=` is zsh
  `EQUALS` expansion and is refused, as is `==` inside a word). A quoted
  word is never empty or made only of `; & | ( ) < >`. Double quotes,
  backslashes, control characters, comments, redirection, grouping,
  substitution and `&` are refused (`reviewer.shell`).
- **Composition.** Segments join only with `|`, `||`, `&&` and `;`, and
  every segment is judged on its own.
- **Program and assignments.** The program word is a bare listed name, never
  quoted and never a path (`/tmp/cat`, `./cat`), and wrappers (`env`,
  `command`, `time`, ...) stay refused. Assignments are allowed only to
  `LC_*`, `LANG`, `LANGUAGE`, `TZ`, `NO_COLOR`, `FORCE_COLOR`, `TERM`,
  `COLUMNS` and `LINES`, with a plain value that holds no `/`; `PATH=`,
  `LD_PRELOAD=`, `DYLD_*=` and `BASH_ENV=` are refused.
- **Options.** Options are whole words spelled as listed: no clusters beyond
  the listed ones (`ls -la`, `nl -ba`), no attached values (`head -n5`,
  `--lines=5`) except the git ones listed as `OPTION=` (`--format=`,
  `--pretty=`, `--sort=`, `--date=`, ...), no abbreviations. A value option
  takes the next word, and that value never starts with `-`. Options come
  before operands; `--` is allowed only right after them (so BSD `cat x --`
  cannot open a file named `--`), and a bare `-` is refused.
  `grep --context` takes only an attached value on GNU and BSD, so it is a
  flag and the next word is the pattern; short `grep -C N` takes the next
  word on both. `grep -f`/`--file`, `rg -f`/`--file`, `date -d` and
  `find -L/-E/-f/-newer/-samefile` are refused (`reviewer.form`), and known
  write, follow and file-list forms keep their specific rules
  (`reviewer.sed`, `reviewer.sort`, `reviewer.uniq`,
  `reviewer.symlink_follow`, `reviewer.file_list`).
- **Programs with their own form.** `sed` runs only as
  `sed -n 'N[,M]p' FILE...`. `jq` is not listed: a program can load
  modules from a search path it sets itself (`include "x" {search:"/tmp"}`).
  `find` takes its starting paths first, then listed primaries only.
  `diff` compares two regular files (a directory diff follows leaf
  symlinks). `rg` must start with `rg --no-config`.
- **Paths.** Every operand the grammar returns, including path option values
  such as `git config --file FILE` and git revision words, is checked
  with symlinks resolved: inside the pane checkout, a granted read path, the
  pane's own message files, or the selected plugin version. `$` and backtick
  stay dynamic even inside quotes (`path.dynamic`). A message file is read
  by one command on its own, never inside a pipeline or list.
- **Git.** `git [--no-pager|-P] [--literal-pathspecs] SUBCOMMAND` with the
  listed subcommands and options. `-C` is refused: git would read the
  repository config found there, where `core.fsmonitor` or a pager runs a
  command. Git reads a word it cannot resolve as a
  revision as a working-tree path (and `git diff A B` with an outside path
  as `--no-index`), so revision words are checked as paths too, and a
  revision part never starts with `.` or `/`, holds `//` or has a dot-led
  component. A glob-bearing pathspec, or a glob word outside `REV -- PATH`,
  needs a global `--literal-pathspecs` (and no other global option) on `diff`,
  `ls-files`, `status`, `log` or `show`; pathspec magic (`:(top)`) is
  refused. `git blame` runs only as `git blame [REV] -- PATH`.
  `git diff --no-index` compares exactly two regular files. `git config`
  reads need `--file PATH` (or `-f PATH`) naming a checked regular file,
  except exactly `git config --get core.hooksPath` and
  `git config --get-all remote.origin.fetch`; `git config --list` without
  it would print the global config, where credentials live. `git reflog`
  reads only as `git reflog [--oneline] [-n N]` or
  `git reflog show [-n N] [--date=FORMAT] [REV]`, `git remote` only bare
  (0.12.12: `-v`, `get-url` and `show -n` print the remote URL, which can
  hold a credential), and `git tag` takes patterns (also after `--`) only
  with `-l`/`--list`.

**Upgrading.** No config or store migration. Reviewer commands that 0.12.10
allowed in a form outside the grammar are now refused with a reason that
names the form; rewrite them in the listed spelling, for example
`head -n 5 FILE` instead of `head -5 FILE`, `git diff 'HEAD~1' -- FILE`
instead of `git diff HEAD~1 -- FILE`, and single quotes instead of double
quotes. Reviewers lose `git -C DIR` (run git from the pane checkout),
`grep -f FILE` (use `-e PATTERN`) and `jq` (read JSON with `cat`, `grep` or
`sed -n`). Pipelines of listed forms (`git log --oneline | head -n 5`) are
now allowed. Executor, orchestrator and coordinator floors are unchanged.
Downgrading restores the 0.12.10 reviewer bypasses.

### Executor read paths

An executor may carry the same `read_paths` field with the same validation
and disk-state rules. The grant is narrower than a reviewer's:

- Only a single literal command from the reviewer read grammar (same
  allowlist, no pipes/redirection/`sed`/expansion, same symlink-follow and
  `diff` limits) may name a granted path, for example
  `cat ../docs/guide.md` from `component-a`. Anything else falls back to
  the unchanged executor containment floor, so composed commands, writes,
  scripts and ungranted siblings are still refused.
- The executor's readable base is its own checkout, its grants, and (from
  0.7.1) the selected installed `girishattri-plugins` version directories; it does not
  gain the reviewer's shell reads of coordination stores. Messages are
  readable only as scoped by "Message store access" (0.10.0).
- Tool `cwd`/`workdir` must still stay inside the checkout; relative
  operands resolve against that effective workdir.
- Edits (native or shell) remain confined to the checkout, apart from
  native writes to its own drafts (draft staging above).

**Attached option values (0.7.4).** No config migration; update the plugin
and restart affected agents. Commands that 0.7.3 wrongly allowed — a path
attached to a short option or placed after `--` that escapes the pane's
scope — are now denied; `cd -- -dir` inside scope is now accepted. Known
limit: only `grep`, `rg`, and `sort` have reviewed option tables; for every
other command any path-looking suffix of a short-option cluster is checked
conservatively, which can deny an unusual in-scope form (use a separate
argument instead). The policy is not a full grammar for arbitrary
executables. Downgrading restores the 0.7.3 gap.

**Selected plugin reads (0.7.1).** Without any `read_paths`, the same
single literal read grammar may also name files inside the *selected*
version directory of an installed `girishattri-plugins` plugin on either
provider (skills, commands, references, scripts as data), so an executor
can read the instructions it was told to use, for example
`cat <claude-cache>/session-chat/<version>/commands/reply.md` (Claude) or
`cat <codex-cache>/session-chat/<version>/skills/reply/SKILL.md` (Codex).
Other versions, unselected plugins, other marketplaces, symlinks whose
canonical target escapes the allowed read roots, composed commands, cache
writes/edits, cache workdirs, and execution stay denied; helpers still run only through the reviewed helper
grammar. Confined orchestrators are unchanged. No config migration;
downgrading restores the earlier denial.

**Provider skill reads (0.7.3).** Reviewers and executors may also use the
same single literal, non-`git` read grammar on provider-installed skill
documentation: Codex system skills under `<codex-home>/skills/.system/<skill>/`
(only while Codex's system-skills marker file exists) and user skills under
`<codex-home>/skills/<skill>/` and `<claude-home>/skills/<skill>/`. The skill
directory must contain a regular `SKILL.md`; every file read must be a
regular single-link file inside that same skill directory, with no symlink
or hidden path component (other than Codex's `.system`). The grant covers
reads only — never workdirs, helper operands, writes, or execution — and
never other provider-home content (`auth.json`, `config.toml`, sessions,
logs, caches, marketplace clones). **Known limit:** skills shipped by
plugins from marketplaces other than `girishattri-plugins` remain denied,
because their active selection cannot yet be determined reliably. No config
migration; downgrading restores the earlier denial.

**Migration / rollback.** Omitted and `[]` are identical to earlier
releases, so existing configs need no change. Adding, changing, or removing
`read_paths` pins new launch identity: restart the affected session
(`workspace restart <session-id>`). Before downgrading to a release without
this field, remove `read_paths` from the config and restart, or validation
will reject the unknown key.
Executor `read_paths` need 0.6.3 or later: before downgrading below 0.6.3,
remove `read_paths` from every executor pane and restart, even though
0.6.2 still accepts the field on reviewers (it rejects it on executors).

**Orchestrator `gh` grammar (0.9.0).** Root and confined orchestrators
route every command whose argv shows a `gh` attempt (the executable, or a
`gh` argument to a non-data command such as a launcher) through one closed
parser before the generic floor; `gh` hidden inside interpreter strings or
script files is not detected. Direct remote mutations (`pr merge/create/close/comment/review/edit/...`,
`run rerun/cancel/delete`, `workflow run/enable/disable`,
`release create/delete/upload/edit`, `repo create/edit/delete/fork/sync/...`,
and `gh api` with any non-GET method, or with fields/`--input` and no
explicit method) are denied as `orchestrator.gh_mutation`. Reviewed literal
reads are allowed as `orchestrator.gh_read`: `run list/view`,
`pr list/view/diff/checks`, `workflow list/view`, `release list/view` with an
explicit `--repo`/`-R OWNER/NAME` (numeric run/PR selectors), positional
`repo view OWNER/NAME`, and `gh api repos/OWNER/NAME/...` or
`repositories/ID/...` with effective GET. With an explicit uppercase `GET`,
`-f`/`-F` fields and `--input FILE`/`-F key=@FILE` are allowed; gh 2.100.0
sends file contents to GitHub even on GET, and confined coordinators keep
path containment for those files. Every other gh-shaped command is
`orchestrator.gh_unsupported`: other subcommands, aliases, extensions, a
path-spelled executable, env assignments, wrappers or launchers (`timeout`,
`nice`, `find -exec`, ...), shell composition, expansions, redirections,
stdin inputs, command-line host overrides (`://` endpoints, `--hostname`),
headers, `--cache`, browser flags, path-valued `-R`, and unknown flags. The
inherited `GH_HOST`/gh configuration remains trusted launch environment, so
this is not a fixed-host guarantee. No owner allowlist or config key
is added; executor and reviewer rules are unchanged. Downgrading restores
the earlier remote-mutation gap and read denials.

### Trusted helpers: exact provenance, literal argv

For **every role**, an installed-plugin helper is recognized only as one
literal, uncomposed `bash <script> args...` segment where `<script>` is the
canonical path of the **selected** installed version under
`~/.claude/plugins/cache/girishattri-plugins/<plugin>/<version>/scripts/<name>.sh`
or the Codex equivalent under `~/.codex/plugins/cache/...`. Rejected: any
prefix or wrapper (`FOO=1`, `env`, `exec`, `sh`), operators, pipes,
redirection, `$`/backtick expansion outside single quotes, multi-line
arguments, `..`/`~`/unnormalized paths, a symlink at any component below the
cache root, a stale or unselected version, a script from another
marketplace or a copy elsewhere, and any basename without a reviewed argv
grammar. "Selected" means: on Claude, the `installPath`/`version` recorded in
`~/.claude/plugins/installed_plugins.json` (user scope, or a project scope
whose `projectPath` is this workspace); on Codex, the plugin enabled in
`~/.codex/config.toml` at the version of the marketplace manifest under
`~/.codex/.tmp/marketplaces/`. Every allowed helper carries an exact
per-basename argv grammar (`harness-policy.py`'s `HELPERS` table) — there is
no grammar-less pass for any role.

The knowledge docs validators take their documented operands:
`validate-links.sh [docs-directory]`, `check-todos.sh [docs-directory]` and
`check-freshness.sh [docs-directory] [days-threshold]`. The directory must be
literal (no glob, `~`, `..` component, or leading `-`) and must resolve,
symlinks included, to an existing directory inside the pane's own cwd: the
workspace root for the orchestrator, the checkout for executors and
reviewers. A relative directory resolves against that cwd. The threshold is
an integer from 1 to 3650.

### The hook

`hooks/hooks.json` registers `scripts/harness-hook.sh` on `PreToolUse` for
`Edit|Write|MultiEdit|NotebookEdit|Bash`. The wrapper exits 0 without
touching Python whenever the harness is inactive; when it is active and
`python3` is missing it fails closed (exit 2). `scripts/harness-policy.py`
(stdlib only, runs on the stock macOS Python 3.9) then:

- allows silently (exit 0, no output);
- in `audit` mode reports one `AUDIT by session-workspace strict-v1
  [rule]: reason (would deny in enforce mode)` line and exits 0 for a
  *policy* denial — it never blocks those; identity, config, and drift
  *integrity* failures still exit 2 in audit mode. **On Claude** that line
  goes to stderr. **On Codex 0.151** stderr of a successful (exit 0) hook is
  discarded, so the Codex registration invokes the same policy with
  `--codex-hook-output`, which renders the identical audit text as exactly
  one inert, compact JSON object on stdout — top-level `systemMessage`
  only, never `hookSpecificOutput`/`permissionDecision`/`updatedInput`, so
  it can never widen a permission. The option changes rendering only; the
  decision (`--decision-json`) is byte-identical with and without it. The
  Claude registration never passes it;
- in `enforce` mode prints one `BLOCKED by session-workspace strict-v1
  [rule]: reason` line to stderr and exits 2, which blocks the tool call —
  on both providers.

**Claimed reviewers fail closed (0.12.11).** Without
`SESSION_WORKSPACE_CONFIG` the hook stays a no-op for ordinary sessions, but
a pane whose `SESSION_WORKSPACE_ROLE`, `SESSION_WORKSPACE_PANE_NAME` or tmux
`@name` holds `reviewer` as a word (`reviewer`, `code-reviewer`,
`example-app-api-reviewer`; not `previewer`) is refused every gated tool call
(`identity.reviewer`) when no readable config of a known schema backs it. A
readable config with the harness off stays a no-op. The wrapper checks the
claim without Python, so a claimed reviewer without `python3` is refused
(`runtime.python`) instead of skipped. The wrapper also accepts no argument
except `--codex-hook-output`; any other argument is refused
(`runtime.args`), so the hook can never reach a policy test mode.

`harness-policy.py --decision-json` (test/parity mode) prints exactly one
compact, key-sorted JSON object —
`{"active","decision","diagnostic","mode","pane","profile","reason","role","rule","tool"}`
with `decision` ∈ `allow | deny | audit` and `diagnostic` the diag/1 object
of a deny (null otherwise) — so both provider trees can
byte-compare decisions. Both Claude-shaped (`tool_name`/`tool_input`, string
`command`) and Codex-shaped (`shell`/`apply_patch`, argv-list or `bash -lc`
commands, `workdir`, JSON-string `tool_input`) payloads are understood.

`harness-policy.py --decision-json --as-role reviewer|executor --as-cwd DIR`
(read-only test mode, 0.12.11) judges one stdin payload as that role working
in `DIR`, under `enforce`, with no read grants, message stores or workspace
identity, and prints the same decision object. It reads no
`SESSION_WORKSPACE_*` variable, runs and writes nothing, and never changes a
live decision; use it to check a list of reviewer commands against a real
checkout before relying on them. `--help` documents it, and
`harness-status.sh --help` prints the exact line. An incomplete or repeated
option is a usage error (exit 2, no decision).

For guarded schema-v3–v5 launches, the same manifest also registers generic
`SessionStart`/`UserPromptSubmit` reminders and the non-blocking Stop health
check. Claude and Codex health output is a top-level `systemMessage` JSON
object; Codex rejects non-empty plain-text Stop stdout. Codex trusts each hook entry by hash, so upgrading to a
release that adds or changes these entries requires accepting/re-trusting the
new session-workspace hook hashes before relying on them.

The exact Codex 0.151 shell hook shape is: `tool_name` `"Bash"` (Codex
canonicalizes `exec_command` to that name), a *string* `tool_input.command`,
and a top-level absolute `cwd` (the turn's cwd) — with **no**
`tool_input.workdir`. Codex does not expose the per-call `exec_command`
workdir in `PreToolUse`, and non-shell reads are not gated by this policy at
all, so **Codex `enforce` must not be described as complete path
containment**: a per-call workdir the policy never receives cannot be
validated. `audit` is the recommended Codex mode until the runtime exposes
that information or a sound mitigation exists.

### Harness known gaps (current release)

- The policy re-validates the config by running `workspace-plan.sh --json`
  on every gated tool call (a jq-only plan; the hook is registered on the
  gated tools only). There is deliberately no cache: a same-uid cache file
  could be planted by an executor.
- Child verdicts and replies travel as single-line `send-message.sh`
  replies, scheduler notes, or multiline drafts staged in the pane's own
  `drafts/<pane-name>/` directory (unique names with a nonce) and dispatched
  with `--reply-to`. After durable success (`Dispatched …`/`Queued …`) delete
  the draft with a native delete tool where one exists (Codex `apply_patch`);
  Claude panes leave it in place, since it is inert after delivery. Keep it
  after a hard failure and retry. A pane without a `messages` grant reports
  the missing grant instead of shortening a long reply. Shell staging remains denied, and nothing sweeps
  drafts automatically. A trusted helper may still consume a pre-existing
  literal `$TMPDIR` file as input, but containment refuses creating one there.
- Executors read dispatch files with the literal `cat '<absolute-path>'`
  command under the message-read rules above; other shell reads of a message
  store, and any read of an ungranted provider inbox, are refused. Executors stage dispatch prompt
  files through draft staging above — edit and shell containment refuse
  creating files under `$TMPDIR`; a temp file that already exists (written
  by a helper or hook) is accepted as helper input only.

**Draft staging migration (0.7.1).** No config change. Reviewers that
staged at the store top level must move to `drafts/<pane-name>/`; the old
top-level exception is removed because it also allowed editing or deleting
other panes' pending dispatch files. Restart affected agents after
updating. Downgrading restores the earlier, broader reviewer exception.
- `harness-status --probe` proves only that the installed policy *decides*
  this pane's floor cases as stated; like the `policy:` line, it cannot prove
  that the provider loaded and trusted the hook.
- `harness-status`/`harness-doctor` probe `harness-policy.py` directly, so
  their `policy:`/`identity.live` verdict is the policy *engine's* decision
  for this process — it assumes the bundled hook is actually loaded and
  trusted by the provider, which the plugin cannot verify from inside a
  pane. `hook.registration` only checks that the bundled `hooks/hooks.json`
  registers `PreToolUse`; provider-side trust prompts (Codex) or plugin
  enablement (Claude) are outside its reach.
- Outside the global gates (escape flags, exact trusted-helper provenance
  and grammar, master-only routing), arbitrary orchestrator shell is gated
  only by the child-root floor, the `git push` denial, and (0.9.0) the
  closed `gh` grammar; project release/build rules stay in `AGENTS.md` and
  project hooks.
- An executor's Git is not narrowed by the floor. The reviewed-git-v1 Git
  floor (no force push, ref deletion, history rewrite or `checkout -B` on
  release) is the `workspace-orchestrator` workflow's contract, so the hook
  allows `git push --force`, `git reset --hard` and `git checkout -B` in an
  executor checkout. Protect release branches on the remote.
- The 0.9.0 `gh` rules are an argv guardrail for root *and* confined
  orchestrators, not subprocess isolation: a script file the pane may run,
  an interpreter fed on stdin, or (root only) `sh -c`/inline interpreter
  code can still invoke `gh`. Where remote mutations must be impossible,
  withhold write-scoped GitHub credentials from orchestrator panes (per-role
  secret visibility). File-backed `gh api` GET inputs transmit the file's
  contents to GitHub.
- Until 0.12.7, `find` actions (`find <child> -delete`, `-exec ...`),
  `rg --pre`, `uniq` with an output operand and `git reflog expire` counted
  as reads, so a root orchestrator's child-root floor did not catch them.
  From 0.12.7 they count as mutations.
- The executor inline-code floor reads the interpreter's own argv. Until
  0.12.8 it did not see a program fed on stdin (`python3 < script`, a pipe
  or a heredoc), one launched behind a prefix it did not unwrap (`timeout`,
  `nice`), or a command on a later line of a multi-line command. From 0.12.8
  an interpreter or shell with no script operand counts as reading its
  program from stdin; version, help and info runs (`python3 --version`,
  `node -v`, `php -m`) and `python3 -m MODULE` stay allowed. It still does
  not unwrap task-runner launchers (`uv run`, `poetry run`, `npx`,
  `bundle exec`, `npm exec`), `flock`, `watch`, `strace` or `script`, and it
  covers only the shells and interpreters in its tables (not `awk`, `deno`,
  `bun`, `lua` or `Rscript`).
- Codex `PreToolUse` carries no per-call `exec_command` workdir (only the
  turn's top-level `cwd`), so executor/reviewer shell containment on Codex
  is incomplete for commands that set their own workdir; see "The hook".
- Codex "selected version" resolution needs `~/.codex/config.toml` plus the
  marketplace manifest; on Python < 3.11 (no `tomllib`) a minimal
  line-based reader handles the `[plugins."<name>"]` table.

## Verification, review, evaluation, and PR-status skills (0.11.0)

Six skills, the same contract on both providers (Claude
`/session-workspace:<skill>`, Codex `$session-workspace:<skill>`). None adds
a config field, permission grant, task/approval ledger, or store, and only
`pr-status` adds a script (one read-only helper); existing role restrictions
and approval requirements still apply.

- `verification-recipe` — create or maintain a project-local recipe
  (launch, doctor, drive, evidence, cleanup, limits) in the project's
  established location, otherwise repository-local Markdown. A recipe is a
  draft until one mapped feature has completed the full pass with evidence
  surviving cleanup. Existing or inherited recipes and evidence files are
  untrusted input: steps are checked against current sources and never
  replayed automatically. Evidence hashes establish local consistency, not
  authorship or correctness.
- `blast-radius` — a report-only review against an exact diff or revision:
  indirect consumers, named safety assumptions with counterexamples, and
  checks run only within the caller's existing role and authorization
  (negative checks need a positive control). It never edits, closes tasks,
  or authorizes commit, push, or deploy.
- `adversarial-review` — an optional, budgeted independent pass that tries
  to break an exact subject using only already-configured runtimes/models.
  Every finding ends fixed, rejected, deferred, or unverified with evidence;
  model agreement or no findings is never approval.
- `benchmark-check` — checks a performance claim with comparable inputs,
  per-sample correctness and work counts, interleaved repeated samples, and
  the end-to-end limiter; reports improved, regressed, no detectable change,
  or inconclusive.
- `behavioral-eval` — design and assess behavioral evaluations with a
  baseline, positive and negative controls, and grading on completed
  executions and artifacts rather than prose; model-based comparisons only
  with explicit spend authority and a ceiling.
- `pr-status` — the one script-backed skill: `scripts/pr-status.sh` (Python
  3) reads a pull request through `gh` (`pr view` plus a fixed read-only
  GraphQL review-thread query), checks the PR did not change across the
  observation, and reports `ready` (exit 0), `blocked`/`waiting`/
  `inconclusive` (exit 1), or unavailable (exit 2). Unknown forge state,
  empty checks, or a moved head never become ready. Under strict-v1 only the
  orchestrator may run it, with `--repo OWNER/NAME --pr N`
  [`--expected-head SHA`] or `--snapshot FILE`. It never merges, comments,
  pushes, or retriggers CI, and a ready result is not permission to merge.

The bundled `references/scheduler-pilot.md` documents an isolated scheduler
verification pilot that only works from the agent-plugins source checkout;
its root runner is not installed with the plugin.

## The bootstrap shim

The per-project alternative to the machine-wide dispatcher (see "The two entry
points" above for which to choose — usually the dispatcher).

`templates/workspace.sh` is copied verbatim into a project as
`<project-root>/workspace.sh`. It contains zero project-specific logic —
all real behavior lives in the plugin's own `scripts/workspace.sh`. On
every invocation it:

1. Resolves `PROJECT_DIR` from `${BASH_SOURCE[0]}` and exports
   `SESSION_WORKSPACE_CONFIG=$PROJECT_DIR/.agent-workspace/workspace.json`.
2. Resolves the plugin root, in order: `$SESSION_WORKSPACE_PLUGIN_ROOT` (an
   explicit override) → the newest **contract-compatible** version under
   the Codex plugin cache (`~/.codex/plugins/cache`) → the newest
   contract-compatible version under the Claude plugin cache
   (`~/.claude/plugins/cache`). Versions are discovered on disk and ordered
   with `sort -V` — no literal version string is ever hardcoded in the shim.
   "Contract-compatible" means running that candidate's
   `scripts/workspace.sh --contract` prints exactly `session-workspace-cli 1`;
   a candidate that doesn't match is skipped, not just picked and hoped
   for.
3. If neither cache yields a compatible install, it exits with both the
   Codex and Claude install commands, and a pointer to
   `SESSION_WORKSPACE_PLUGIN_ROOT` as a manual override.
4. `exec bash "$root/scripts/workspace.sh" "$@"`.

## Adopting it in a new project

**Once per machine** (not per project):

1. Install the plugin (Claude: `claude plugin install session-workspace@girishattri-plugins`;
   Codex: `codex plugin add session-workspace@girishattri-plugins`).
2. Run `workspace-install` (the `install` verb) to put the machine-wide
   dispatcher on your `PATH` as `workspace`. From then on `workspace <verb>`
   works inside **any** configured project — see "The two entry points" below.

**Then, per project:**

3. Create `.agent-workspace/workspace.json` (`schema_version: 1`, `2` for the
   harness, `3` for optional shared guards, `4` for reviewed Git
   orchestration, or `5` for scoped environments — see "Harness" above and
   "Schema v5 root-scoped environment orchestrators" below) describing
   the project's runtimes, roles, stores, sessions/panes, and behavior — see
   `scripts/workspace.schema.json` for the documented shape, or copy one of
   `scripts/fixtures/valid/*.json` as a starting point, and the
   "Configuration reference" section below for the full field list.
4. **Recreate any coordination directories the config expects by hand.**
   The engine does not create them for you — see "known limitations".
5. Run `workspace doctor` and fix everything it reports as `ERROR`
   (`WARN` is advisory).
6. Run `workspace plan` and check it matches the topology you intended
   — this step mutates nothing, so it's safe to iterate on.
7. Run `workspace start` to bring the workspace up.

Nothing is copied into the project: adoption is the config file plus whatever
coordination directories it expects. There is no per-project script to keep in
sync, and no file to go stale when the engine changes.

## The two entry points

The engine can be reached two ways. Both resolve the plugin identically —
newest version first, each candidate contract-checked with
`scripts/workspace.sh --contract` against `session-workspace-cli 1`, no version
string hardcoded anywhere — and neither ever pins a marketplace name.

| | `templates/workspace-dispatcher.sh` | `templates/workspace.sh` |
|---|---|---|
| Installed as | `~/.local/bin/workspace`, once per machine | `<project>/workspace.sh`, once per project |
| Installed by | the `install` verb | copying it yourself |
| Serves | every configured project | the project it sits in |
| Finds the config by | the engine's upward walk from `$PWD` | pinning `SESSION_WORKSPACE_CONFIG` to its own directory |
| Refresh when the template changes | `install` again (idempotent; an external upgrade flow may call it unconditionally) | re-copy by hand, per project |

**Prefer the dispatcher.** The shim exists for the case where a project must be
pinned to its own config regardless of `$PWD`, or where you cannot rely on
`PATH` — a CI job invoking `./workspace.sh` by relative path, for instance. It
is not deprecated; it is simply the narrower of the two.

Both are optional. The plugin's own commands and skills (`/session-workspace:workspace-*` on
Claude, `$session-workspace:workspace-*` on Codex) resolve the config the same
way, so a project with neither entry point installed still works from inside an
agent session. What the dispatcher adds is a workspace launchable by a human, a
shell script, or CI with no provider CLI in the loop.

## Known limitations

These are honest gaps in the current implementation, not aspirational
roadmap items — read them before depending on the behavior they describe.

- **`stores.memory.root` does not export `KNOWLEDGE_MEMORY_HOME`.**
  `coordination_var_name()` (both in `adapters.sh` and `compute-plan.jq`)
  only maps `messages`/`scheduler`/`contexts` to an exported env var;
  `"memory"` is not a valid `stores.pin` entry (schema-rejected) and has no
  corresponding export at all. If a project wants its panes' `knowledge`
  memory store to actually point at `stores.memory.root`, it must restate
  that same path as a value in `env.groups.<g>.values` (e.g.
  `"KNOWLEDGE_MEMORY_HOME": "${PROJECT_ROOT}/.agents/memory"`). Nothing
  keeps that restated value and `stores.memory.root` in sync — if you change
  one without the other, they silently diverge and the memory store a pane
  writes to differs from the shard the config claims to use.
- **The engine never creates coordination directories.** The old
  hand-maintained launchers each did their own `mkdir -p` /
  `chmod 700` of the `messages`/`scheduler`/`contexts` directories under
  `stores.base` (and the memory root) before starting panes. This engine
  does not — the only directories it creates are its own state directory
  (`$XDG_STATE_HOME/session-workspace/<project-id>/`, 0700), its persistent
  `layouts/` subdirectory, and its transient `lock/`; and — only when a
  `browser` block is configured — the shared port registry
  (`$XDG_STATE_HOME/session-workspace/browser-ports/`), its transient `.lock/`,
  and the derived Chrome profile directory
  (`browser.profile_dir`, created by `workspace-start.sh` before launching the
  browser session). Coordination
  directories are never among them. On a machine where those coordination directories already
  exist from a prior run this is harmless; on a genuinely fresh clone it
  means the first agent to write to an unmanaged store, or a strict
  consumer of one, can fail until something creates the directory.
- **A freshly split "extra" pane keeps the invoking cwd.** `_sw_split_extra_pane`
  (used to fill a gap when a session has fewer existing panes than the plan
  needs) calls `tmux split-window` without `-c`, so the new pane inherits
  the split source's cwd, not the pane's configured `cwd`. Normally this is
  invisible because the pane is immediately respawned with `-c` set from
  the plan. But with `--no-agents` (on `start`/`reconcile`) or a
  service-role pane under `--no-services`, `_sw_launch_pane` returns before
  that respawn ever runs — so a pane created that way is left sitting in
  whatever directory the split happened from, not the configured `cwd`.
- **A coordination-pinned env var is inexpressible without also
  session-mirroring it.** A group's `values` always enter each managed
  pane's *own* process environment. `env.groups.<g>.pin_to_session: true`
  *additionally* exports the `stores.pin` coordination vars to that pane
  and mirrors the pinnable group+coordination subset into the tmux
  *session* environment for later, unmanaged panes to inherit; `false`
  only suppresses those coordination vars and the session mirroring.
  There is currently no way to say "give this pane the coordination vars,
  but don't mirror them session-wide" — the two travel
  together.
- **`workspace-doctor`'s post-config checks are skipped, correctly, once
  config validation fails — and the exit code reflects that failure.**
  Every check after `config.validation` (pane cwds, secrets-file gates,
  state dir, runtime resolution, coordination-base drift, session-chat
  helper) is gated on validation having actually passed, so none of them
  run against data that couldn't be trusted (an unresolved `project.root`,
  a malformed `stores.base`, etc.). The `config.validation` check itself
  counts as an `ERROR` in that case, which does correctly non-zero the
  process exit code — `doctor` does not report a false "clean" green exit
  when the config is broken.

## Configuration reference

`.agent-workspace/workspace.json`, `schema_version: 1`, `2`, `3`, `4`, or `5`
(v2 adds the harness; v3 adds optional shared guards; v4 adds optional
reviewed Git orchestration; v5 adds scoped environments, described at the end
of this file). `validate-config.sh` is the runtime authority: it
enforces its explicit key, safety, and cross-field checks
(`validate-structural.jq` for the pure-jq structural half — unknown/missing
keys, uniqueness, charset/safety rules, the harness/guards/orchestration
rules, and the `project.display_name` / non-empty `sessions` /
`window_index` checks — plus filesystem checks in `validate-config.sh`
itself for path containment and the secrets gates).
`scripts/workspace.schema.json` documents the supported contract but is not
executed by anything, and not every scalar/cardinality constraint written
there is mirrored as an executable preflight check — a config outside the
documented shape is unsupported even where an unmirrored constraint happens
not to be rejected.

Two interpolation tokens are recognized in any string value, and nowhere
else: a literal `${PROJECT_ROOT}` **prefix** is replaced with the config's
canonicalized project root, and a literal `${PROJECT_ID}` **substring**
(anywhere) is replaced with `project.id`. No other `${...}` text, env-var
expansion, or shell substitution happens anywhere in the config.

### `browser` (optional)

This binds one pane of an existing session to a persistent Chrome DevTools
instance. The selected pane must omit `command` and `port`; the engine derives
both so the endpoint has one source of truth. Since 0.5.1 that session may
also hold other `service` panes (for example the project's dev servers): the
browser binding never touches a sibling pane's `command`, `port`, or status.

| Field | Type | Required | Meaning |
|---|---|---|---|
| `browser.session_id` | string | yes | Existing session that contains the Chrome pane. |
| `browser.pane_name` | string, `^[A-Za-z0-9._-]+$` | no | Name (after `${PROJECT_ID}` interpolation) of the one pane inside `browser.session_id` that receives the Chrome argv. **Required when that session has more than one pane.** A one-pane session may omit it and binds its sole pane, exactly as before 0.5.1. An unknown name, a pane that belongs to another session, or an unsafe string is rejected. |
| `browser.port` | integer, 1–65535 | yes | Loopback DevTools port. Start records machine-local ownership and refuses a live allocation owned by another project. |
| `browser.chrome_program` | string | yes | Chrome executable name or absolute path. `doctor` checks resolution without executing it. |
| `browser.mcp_package` | exact `chrome-devtools-mcp@x.y.z` | yes | Pinned MCP package; floating tags such as `@latest` are rejected. |
| `browser.mcp_server_name` | `A-Za-z0-9_-` | no | MCP entry name; default `chrome-devtools`. |

The selected pane must be non-optional, use a `service` role with the built-in
`shell` runtime, and omit `command` and `port`; only those five rules apply to
the selected pane, sibling panes are unconstrained. Only the selected pane
receives the derived Chrome argv, `browser.port`, and `browser: true` in the
plan, and the normalized plan echoes the concrete selection as
`browser.pane_name`. `status` reports DevTools readiness for that pane alone
(`n/a` for every other pane). The port-collision check stays global: `browser.port`
may not duplicate any explicit `sessions[].panes[].port`.

The Chrome argv always binds `127.0.0.1`; its profile is derived as
`${XDG_CACHE_HOME:-$HOME/.cache}/session-workspace/chrome/<project.id>`.
`start` waits for `/json/version`, while `status` and `doctor` report endpoint
readiness. `workspace browser-config` previews the Codex/Claude MCP entries;
`workspace browser-config --apply` backs up and merges them. Start the browser
session before opening a new Codex or Claude session.

Lifecycle stays keyed on `browser.session_id`. `workspace start <session>` (or
`all`) claims the port, starts every pane of that session, then waits for
`/json/version`; `--no-services` suppresses the Chrome pane like any other
service pane and skips the claim and the wait; `workspace stop <session>`
releases the port. When Chrome shares a session with dev servers, start or
stop it on its own with `workspace start <session> --pane <browser pane>` and
`workspace stop <session> --pane <browser pane> --confirmed` (see "Single
service panes on demand"). `workspace restart <session>` still bounces every
pane in that session, and a failed sibling slot suppresses the readiness
wait and its `[ready]`/`[failed]` report. Because a `split_tree` layout with
`only_when_fresh: true` is built only while the window has exactly one pane,
moving Chrome into an already-running session requires stopping that session
once so the new tree is built fresh; a saved `retain_layout` file from the old
pane count is rejected by tmux and overwritten on the next successful start.

### `project` (required)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `project.id` | string, `^[a-z0-9][a-z0-9-]*$` | yes | — | Slug used for session-name prefixes, the state directory, and managed marker values. |
| `project.display_name` | string | no | `project.id` | Human-readable name shown in `plan`/`status` output. |
| `project.root` | string | yes | — | Path to the project root, resolved relative to the directory containing `.agent-workspace/` (or the config file's own parent, if loaded from an unconventional location). Every pane `cwd` and coordination-store path is validated to resolve inside this root. |

### `runtimes` (required, object keyed by runtime name)

Named launch profiles. A pane's role picks one of these by key; there is no
free-form "custom command" anywhere, and no interactive runtime menu — what a
pane launches is entirely decided by the config, so `plan` can show it exactly
and `start` is reproducible.

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `runtimes.<name>.program` | string | yes | — | Executable name or path (looked up on `PATH` if not absolute). |
| `runtimes.<name>.args` | array of strings | no | `[]` | Static argv appended after `program`, before any engine-built flags. Validated to never contain a dangerous flag (see below). |

The runtime *key* itself (e.g. `claude`, `codex`) is what a role's
`roles.<r>.runtime` field references. A `roles.<r>.runtime` of `shell`
is always available and does not need a `runtimes.shell` entry — it
launches the pane's interactive shell (or, for a service pane, its
configured `command`) with no engine-built agent flags at all.

### `roles` (required, object keyed by role name)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `roles.<r>.runtime` | string | yes | — | A key from `runtimes`, or `shell`. |
| `roles.<r>.agent.model` | string | no | no flag emitted | Passed as `--model VALUE` (claude and codex). `"inherit"`, `"null"`, or omitted all mean "emit nothing" — resolved identically to an omitted value. |
| `roles.<r>.agent.effort` | string | no | no flag emitted | Claude: `--effort VALUE`. Codex: `-c model_reasoning_effort=VALUE`. Same `"inherit"`/omitted-means-nothing rule. |
| `roles.<r>.agent.profile` | string | no | no flag emitted | Claude: `--agent VALUE`. Codex: `-p VALUE`. Same rule. |
| `roles.<r>.agent.permission_mode` | enum: `inherit`, `default`, `plan`, `acceptEdits`, `dontAsk` | no | no flag emitted | Claude only, emitted as `--permission-mode VALUE`; never emitted for codex even if set. `bypassPermissions` is **not** in the allowed enum at all — it is rejected at the schema level, and `adapters.sh` additionally refuses to build argv containing it even if fed unvalidated input directly (defense in depth). |
| `roles.<r>.grants` | array of strings | no | `[]` | Store names (`messages`, `scheduler`, `contexts`, `memory`) this role's agent panes receive as `--add-dir` grants. Only applies to non-`shell` runtimes — a shell-role pane never gets engine-built `--add-dir` flags. A store not listed here is never granted to that role, regardless of `stores.pin` (see `grants-unpinned-store` validation below). |
| `roles.<r>.env_group` | string | no | `"none"` | Key into `env.groups`. `"none"` resolves to `{values: {}, pin_to_session: false}` if that key isn't defined. |

`agent.model`/`effort`/`profile`/`permission_mode` can also be set **per
pane** (`sessions[].panes[].agent.*`), which takes precedence over the
role-level value; an `"inherit"` at either level defers to the next level
down, and both omitted resolves to no flag.

### `stores` (required)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `stores.base` | string | no | `.tmp` | Coordination-store root, relative to `project.root` unless absolute. Must resolve inside the project root (lexically, and — for whatever portion already exists on disk — physically, so a symlink can't smuggle it out). |
| `stores.pin` | array, enum of `messages`/`scheduler`/`contexts`, unique | yes (key must be present; may be `[]`) | — | Which coordination stores get exported as env vars (`SESSION_CHAT_TARGET_MESSAGES_DIR`, `SESSION_SCHEDULER_HOME`, `SESSION_CONTEXT_HOME` respectively) at all. These three var names are rejected outright if they appear literally in any `env.groups.*.values` — `stores.pin` is their only source of truth, so the two can never disagree. |
| `stores.overrides` | object, string values | no | `{}` | Per-store path override, keyed by store name (`messages`/`scheduler`/`contexts` — any other key is accepted structurally but has no consumer). Overrides `stores.base + "/" + store` for that one store. Also validated to resolve inside the project root. |
| `stores.memory.mode` | enum: `shared`, `per-pane` | no | `shared` | `shared`: every granted pane gets the same memory root. `per-pane`: each pane gets its own subdirectory (see `shard` below). |
| `stores.memory.root` | string | no | `.agents/memory` | Memory store root, relative to `project.root` unless absolute. Validated to resolve inside the project root. **Produces no env export** — see known limitations. |
| `stores.memory.shard.strip_prefix` | string | no | `""` | Only used when `mode: per-pane`. A literal prefix stripped from the pane name to derive its shard subdirectory (typically `"${PROJECT_ID}-"`, already interpolated by the time it's used). |
| `stores.memory.shard.strip_suffixes` | array of strings | no | `[]` | Suffixes stripped from the (already prefix-stripped) pane name, in list order, first match wins per suffix. |
| `stores.memory.shard.fallback` | string | no | `master` | Shard name used when stripping prefix/suffixes leaves an empty string. |

When `stores.memory.mode` is `per-pane`, every dev pane name must start with
`"${project.id}-"` — enforced structurally, not just as a shard-naming
convention.

### `env` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `env.groups.<g>.values` | object, string values | yes if the group exists | — | Extra `NAME=value` pairs exported into every pane whose role's `env_group` is `<g>`. Keys must match `^[A-Z_][A-Z0-9_]*$` (config validation rejects a key that does not) and must not name a reserved `SESSION_WORKSPACE_*` identity var (also rejected by validation). A key that collides with one of the three engine-always identity vars (`TMUX_PANE`, `SESSION_CHAT_PANE_NAME`, `KNOWLEDGE_PANE_NAME`) passes validation but is ignored by the `adapters.sh` renderer: the engine-always value is set last and wins. The renderer also drops a charset-invalid name with a warning, but that is defense in depth for a direct, unvalidated invocation — normal config validation has already rejected it. The engine also always ships a fixed `KNOWLEDGE_AUTO_*`/`KNOWLEDGE_CONSOLIDATE_NUDGE` default block (identical across every adopter today); values here override those defaults by name. |
| `env.groups.<g>.pin_to_session` | boolean | no | `false` | The group's `values` always enter each managed pane's own process env. `true` *additionally* exports the `stores.pin` coordination vars to that pane and mirrors the pinnable group+coordination subset into the tmux session environment via `tmux set-environment` (non-hidden, session-scope) so a later, unmanaged pane in that session inherits it too; `false` only suppresses those coordination vars and the session mirroring (see "known limitations"). |
| `env.pane_name_aliases` | array of strings | no | `[]` | Extra env-var names, each set to the pane's own name (replaces a project's bespoke `<PROJECT>_CODEX_PANE_NAME`-style variable). Same charset rule and engine-always collision rule as group values. |

Three variables are **engine-always** and never config-driven, at any
level: `TMUX_PANE` (re-pinned to the real target pane id after respawn),
`SESSION_CHAT_PANE_NAME`, and `KNOWLEDGE_PANE_NAME`. They are computed last
and win unconditionally over anything a group value or alias tried to set.
`KNOWLEDGE_PANE_NAME` in particular is an authorization boundary for who
may write to the memory store, so it is also never one of the vars
mirrored into session env — a session-scoped identity would let a
hand-added pane in that session present itself as a different pane.

### `secrets` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `secrets.env_file` | string | no | — | Relative (to `project.root`) or absolute path to a `KEY=value` file. Optional even when `secrets` exists: without it, allowlisted keys resolve from the launching process's environment only. When set, the file gates in "Secrets" above apply. |
| `secrets.allow` | array of key strings (`^[A-Za-z_][A-Za-z0-9_]*$`) or `{key, roles}` objects | no | `[]` | The only keys any pane may ever request from `env_file`. A string inherits `visible_to_roles`; an object's `roles` (unique, known role names, may be empty) intersects with it. Duplicate keys across either form are invalid. |
| `secrets.visible_to_roles` | array of strings | no | `[]` | Global ceiling: roles whose panes may receive any key. A role not listed here gets nothing, regardless of `allow`. |
| `secrets.on_missing` | enum: `warn`, `fail` | no | `warn` | Behavior when a key the pane's role is entitled to is present in neither the launching process's environment nor `env_file`. `fail` aborts that pane's launch; `warn` starts it without the key. |

### `sessions` (required, array, minimum 1 entry)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `sessions[].id` | string | yes | — | Stable identifier used as the `TARGET` argument to every lifecycle verb, and as the layout-persistence file key. |
| `sessions[].name` | string | yes | — | The actual tmux session name (commonly `"${PROJECT_ID}-<id>"`). |
| `sessions[].window_index` | integer ≥ 0 | no | `0` | Window index within the session that holds this session's panes. |
| `sessions[].retain_layout` | boolean | no | `false` | If true, the engine saves the window's `#{window_layout}` at the end of a mutating `start`/`reconcile --apply` pass over that session; on the next `start`/`reconcile` it first creates/fills pane slots and applies the configured layout selection, then restores the retained layout on top. During `stop`/`restart`, the *current* manual layout is captured before killing only when `behavior.save_before_stop` is `true` and `--no-save` was not passed — so manual resizing survives a restart only under those conditions, not unconditionally. |
| `sessions[].layout.kind` | enum: `standard`, `split_tree` | yes (if `layout` present) | — | `standard`: named tmux layout applied via `select-layout` after slot-filling. `split_tree`: an explicit, ordered sequence of splits (see below). |
| `sessions[].layout.name` | string | no | `"tiled"` | Only used when `kind: standard` — the tmux layout name passed to `select-layout`. |
| `sessions[].layout.only_when_fresh` | boolean | no | `false` | Only used when `kind: split_tree`. Set this explicitly to `true` to construct `layout.nodes`; construction then occurs **only** when the window currently has exactly one pane. When false, or once the window has multiple panes, existing panes are matched by marker/position instead (so a previously built split tree is never rebuilt on a second `start`). |
| `sessions[].layout.mask_after_split_hook` | boolean | — | (always applied for `split_tree`) | Whether the engine masks the window's `after-split-window` hook during construction and restores it byte-for-byte afterward, so a user's own tmux hooks can't interfere mid-build. This is always done for a fresh split-tree build; the field exists in the schema for documentation/explicitness. |
| `sessions[].layout.nodes` | array of `{id, from?, dir?, percent?}` | yes (if `kind: split_tree`) | — | Ordered split instructions. The first node has no `from`/`dir`/`percent` (it's the window's existing single pane). Every subsequent node splits the pane at `from` in direction `dir` (`v` or `h`) reserving `percent` (1-99) for the new pane, emitted as `-l <percent>%` (never the deprecated `-p <pct>`). |
| `sessions[].layout.pane_order` | array of node ids | yes (if `kind: split_tree`) | — | Explicit, authoritative mapping from split-tree node id to `panes[]` slot order — a visual layout can't otherwise express "pane order differs from split order." |
| `sessions[].panes[].name` | string | yes | — | The pane's `@name` (session-chat addressing identity) and managed-marker pane value. Enforced unique across the whole config. |
| `sessions[].panes[].role` | string | yes | — | A key from `roles`. |
| `sessions[].panes[].runtime` | string | no (v5 only) | role runtime | Declared `runtimes` key or `shell`; pane overrides role. Harness panes cannot resolve to shell; browser-selected panes must resolve to shell. |
| `sessions[].panes[].cwd` | string | no | session/window default | Relative (to `project.root`) or absolute working directory. Validated to resolve inside the project root; a missing directory is a hard validation error **unless** `optional: true`. |
| `sessions[].panes[].optional` | boolean | no | `false` | A missing `cwd` for an optional pane is reported (INFO in `doctor`, "skipped" in `start`) rather than failing validation/the slot. |
| `sessions[].panes[].command` | array of strings, min 1 item | no | (agent argv, or interactive shell) | For a `shell`-runtime (typically `service`-role) pane: literal argv to run instead of an interactive shell. A bare string command is rejected — it must be an array, so there's never a shell re-parsing step. |
| `sessions[].panes[].port` | integer, 1-65535 | no | — | First-class metadata (surfaced in `plan`/`status` output); does not change what gets launched or add a `--port` flag anywhere. A pane with `port` and `command` is refused by `start --pane` (and by a schema-v5 start) while another process holds the port, naming the holder's PID. |
| `sessions[].panes[].idle_stop_minutes` | integer, 1-1440 | no | — (never stopped) | `service` panes only, and only one with a port to watch: the browser pane or a pane with `port`. A watcher stops the pane after this many minutes with no inbound connection to that port (for the browser, no CDP commands; keepalive pings on an open connection do not count) and records why. See "Single service panes on demand". |
| `sessions[].panes[].idle_activity` | array of unique strings: `connections`, `output` | no | `["connections"]` | What counts as use for a pane with `idle_stop_minutes` and `port`; refused without `idle_stop_minutes`, on a non-`service` pane and on the browser pane. `connections`: an inbound connection to the port (on Linux, also one the server closed in the last 60 seconds). `output`: new output in the pane since the previous sample, for a dev server that closes every connection after its response but logs each request. Use is either selected signal. Any periodic output keeps the pane up, which is why `output` is opt-in. |
| `sessions[].panes[].launch` | enum: `always`, `on_demand` | no | `always` | `on_demand`: an executor or reviewer pane of an active strict-v1 harness (schema 2-5) that a full `start`/`reconcile --apply` leaves down; the orchestrator starts it with `start --pane` (which waits for the agent's input line) and closes it with `stop --pane` (refused while it is busy). Refused on any other role and in a `split_tree` session. See "On-demand workers". |
| `sessions[].panes[].read_paths` | array of ≤16 strings | no | — (no extra reads) | Active strict-v1 **reviewer** or **executor** panes only (schema v2–5). Existing files/directories the pane's shell may read in addition to its cwd; see "Reviewer read paths" and "Executor read paths". Any other role, or an inactive harness, is a validation error. |
| `sessions[].panes[].agent.*` | see `roles.<r>.agent.*` | no | role-level value, or no flag | Pane-level override of `model`/`effort`/`profile`/`permission_mode`, taking precedence over the role's own value. |

### `behavior` (optional)

| Field | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `behavior.default_start_target` | string | no | `"all"` | The `TARGET` a bare `start` (no positional argument) uses. `restart` is unaffected — it always forwards one explicit target to both its `stop` and `start` halves, so the two can never disagree. Must be `"all"` or one of `sessions[].id` — anything else is a validation error, so it can never surface as "unknown session target" at launch time. An explicit positional `TARGET` always wins. |
| `behavior.attach` | enum: `if_terminal`, `never` | no | `if_terminal` | Interactive-attach policy, applied by `start` only after a fully successful run. `if_terminal`: attach to the started session when stdout is a terminal — `switch-client` when already inside tmux, `attach-session` otherwise; a non-terminal (automated) run attaches nothing and reports `attach: skipped (not a terminal)`. `never`: never attach. `--no-attach` on the CLI forces it off regardless of this field. Every branch prints one `attach: ...` line, so the decision is always visible. |
| `behavior.stop_scope` | enum: `selected`, `all` | no | `selected` | `selected`: `stop`/`restart` only touch the target session(s). `all`: widen to every session on the server carrying this project's marker. `--all` on the `stop` CLI forces `all` regardless of this field. |
| `behavior.save_before_stop` | boolean | no | `false` | If true, `stop` saves the window layout (when `retain_layout: true`) and invokes tmux-resurrect's save script (if installed) before killing anything. `--no-save` on the CLI forces this off regardless of the config value. |
| `behavior.session_chat_helper.resolve` | string | no | `"always"` | `"never"` skips the session-chat helper-resolution check in `doctor` entirely (reported `OK`, not consulted). Any other value resolves the helper via the plugin cache/source tree. |
| `behavior.session_chat_helper.on_missing` | enum: `warn`, `fail` | no | `"warn"` | What happens when the session-chat helper does not resolve. `fail`: `start` aborts non-zero *before* taking the project lock or touching tmux (nothing is half-created), and `doctor` reports `ERROR`. `warn`: `start` proceeds with a warning and panes come up without inter-pane messaging; `doctor` reports `WARN`. Both verbs resolve the helper through the same function, so `doctor`'s verdict and `start`'s behavior cannot disagree. |

### `harness` (optional in schema v2+; guard-capable in schema v3+)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `harness.enabled` | boolean | yes (if the block exists) | `false` is inactive and must be the only key. `true` requires `mode`, `profile`, `roles`, and `gates`; schema-v3–v5 `guards` remain optional. |
| `harness.mode` | enum: `audit`, `enforce` | when enabled | `audit` reports would-be policy denials on stderr without blocking; `enforce` blocks (exit 2). Integrity failures block in both. |
| `harness.profile` | const `strict-v1` | when enabled | The only profile. No other value is accepted. |
| `harness.roles.orchestrator` / `.executor` / `.reviewer` | string (a `roles` key) | when enabled | Exactly these three keys; three distinct existing role names; none may be `service` or use the built-in `shell` runtime. |
| `harness.gates.plan_review_ttl_minutes` / `.audit_ttl_minutes` | integer 1–1440 | when enabled | Exactly these two keys. Freshness windows for plan review and audit (reserved for the scheduler integration; validated now so they are stable config). |
| `harness.guards.protected_files.profile` | const `credentials-lockfiles-v1` | v3–v5, if pack exists | Generic protected credential/lockfile basenames; orchestrator Edit-family only. |
| `harness.guards.protected_files.extra_basenames` | unique exact-basename array | no | Additive names matching `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`; no slash or glob. |
| `harness.guards.orchestrator.deny_child_chdir` | boolean | no | Deny orchestrator process-directory hops into child roots. |
| `harness.guards.lifecycle.session_reminder` / `.prompt_reminder` | boolean | no | Generic SessionStart/UserPromptSubmit routing reminders. |
| `harness.guards.workspace_health.warn_root_dirty` | boolean | no | Orchestrator-only Stop warning for root working-tree changes. |
| `harness.guards.workspace_health.warn_missing_panes` | boolean | no | Orchestrator-only Stop warning for missing non-optional, non-service panes. |
| `harness.guards.workspace_health.branch_ahead.base` / `.release` | safe literal branch names | if pack exists | Orchestrator-only neutral Stop fact per executor child root; refs are distinct, contain no `..`, and do not end in `/` or `.lock`. |

Cross-field rules for an enabled harness: exactly one non-service pane uses
the orchestrator role; every executor pane declares a non-`.` `cwd` that
does not resolve to the project root and has exactly one reviewer pane with
the identical `cwd`; every reviewer pane pairs with exactly one executor.

### `orchestration` (optional, schema v4 or v5)

| Field | Type | Required | Meaning |
|---|---|---|---|
| `orchestration.enabled` | boolean | yes (if the block exists) | `false` is inactive and must be the only key. `true` requires an enabled strict-v1 harness, `stores.pin` containing `messages` + `scheduler`, `profile`, and `targets`. |
| `orchestration.profile` | const `reviewed-git-v1` | when enabled | The only orchestration profile. The fixed lifecycle, approvals, and Git floor live in the profile, never in config. |
| `orchestration.targets[].id` | unique `^[a-z0-9][a-z0-9-]*$` | yes | How the orchestrator names the target. |
| `orchestration.targets[].cwd` | safe relative path | yes | Must exactly equal one configured executor pane `cwd` (and thereby its paired reviewer), resolve to an existing child inside the project root, never `.`, no `..`, unique after physical resolution. |
| `orchestration.targets[].remote` | `^[A-Za-z0-9][A-Za-z0-9._-]*$` | yes | Named Git remote only — a URL can never appear here. |
| `orchestration.targets[].work_branch` / `.release_branch` | distinct safe literal refs | yes | No `..`, no trailing `/` or `.lock`. |
| `orchestration.targets[].deploy.strategy` | const `merge-no-ff-v1` | yes | Reviewed `--no-ff` work→release merge with the six-check executor preflight. |
| `orchestration.targets[].deploy.align_work_after_release` | boolean | no (default `false`) | Authorizes only a post-release `--ff-only` fast-forward of work to the release merge commit; anything non-fast-forwardable stops and reports. |

### Argv-safety rules validated regardless of the above

These aren't config fields, but they explain why certain otherwise-valid-looking
config values get rejected:

- Any static arg in `runtimes.<r>.args`, and any resolved
  `agent.permission_mode`, is rejected if it matches a hard-coded dangerous
  set: Claude's `bypassPermissions` (any spelling — bare, `--permission-mode`
  flag, or `=`-joined), and codex's
  `--dangerously-bypass-approvals-and-sandbox` /
  `--dangerously-bypass-hook-trust`.
- `env.groups.*.values` keys, `env.pane_name_aliases` entries, and
  `secrets.allow` entries are all
  charset-restricted (uppercase-snake-case for env names, identifier shape
  for secret keys) specifically so a value can never be crafted to break out
  of the rendered `export NAME=VALUE;` string the pane's shell evaluates —
  even though the *value* half of that string is always `%q`-quoted, an
  unquoted, attacker-chosen *name* could still inject a second shell
  statement. (`secrets.visible_to_roles` and `secrets.allow[].roles` entries are
  validated differently — as references to existing role names, not as
  export names.)

## Schema v5 root-scoped environment orchestrators

See the [environment contract](skills/session-workspace/references/environments.md)
and [shared-root template](templates/workspace-shared-root.json). Environment masters
can share the project-root cwd while retaining their own worker routing and task
metadata. An unbound root master is optional when every worker environment has a
master. Control-directory coordinators retain their confined policy. Root-scoped
masters retain root shell/edit permissions and guard packs, with all child checkout
mutations and `git push` denied. Shared-root write coordination is a user rule.

Command-less service shells and browser panes may use any project-contained cwd;
they carry no harness policy, so checkout containment protects no role boundary.
Services with commands remain within their environment checkout.

The `browsers[]` profile path is `chrome/<project.id>/sessions/session-<sid>`;
singular `browser` retains `chrome/<project.id>`. Doctor emits INFO with a manual
copy command when the legacy profile exists but the session profile does not.
Stop Chrome first and exclude `sessions/` during copying. No automatic migration
runs. To merge two v4 configs, preserve pane names, merge sessions, choose one
`stores.base`, and restart all sessions. Stop the retired second project using its
old config first to release port allocations owned by that project's id.

The shared-root template has no unbound root orchestrator. Run workspace
installation, browser MCP configuration (`workspace browser-config --browser
services` or `vue3-services`) and shared-store cleanup from a user terminal outside
the harness, or configure an unbound root to own those operations. Root-scoped
masters retain these helper restrictions; do not unset launcher identity to bypass
them. In mixed topologies, a root-scoped master can message a confined master, but
the confined master cannot reply directly; use the unbound root as relay when one
exists. See the shared-root template's adjacent `workspace-shared-root.md` notes.
