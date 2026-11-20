# Independent environments (schema v5) and peer orchestrators (schema v6)

Schema v5 adds scoped environments with their own coordinators. Schema v6 keeps
everything in v5 and adds peer orchestrators (see "Peer orchestrators (schema 6)").
A v6 config without `peers` behaves exactly like v5. V5 retains v1-v4 support. Start with `templates/workspace-multi-environment.json`.
Create its child repositories and separate coordinator directories first; the
engine does not clone repositories or install product dependencies.

```json
{"schema_version":5,"environments":[
  {"id":"web","cwd":"component-a","development":["dev-web"],
   "services":["service-web"],"orchestrator":"sample-web-master"},
  {"id":"vue3","cwd":"component-b","development":["dev-vue3"],
   "services":["service-vue3"],"orchestrator":"sample-vue3-master"}
]}
```

The usual project/roles/runtimes/stores/sessions fields are also required. Names
are explicit references, not conventions. Prefix tmux and pane names with
`${PROJECT_ID}-` to avoid server-wide collisions. Every environment owns a
nonoverlapping child cwd and disjoint session lists. Service sessions contain only
shell panes. With the harness active each environment has one executor/reviewer
pair at its repository root. Its optional orchestrator is in a development session,
uses the configured orchestrator role and is non-optional. Its cwd may be the
workspace root (root-scoped), or a distinct control directory outside all child
repositories (for example `control-web`). Zero or one unbound root orchestrator
may remain at workspace root. Without one, every environment with workers must
declare an orchestrator; otherwise workers without a local coordinator route to root.
Command-bearing service panes stay inside their environment checkout. Command-less
service shells and selected browser panes may live anywhere inside the project
root. They carry no harness policy, so checkout containment protects no role boundary.
Unbound shell sessions can host shared services; group selection leaves them alone.

## Lifecycle and boundaries

Use the installed `scripts/workspace.sh` dispatcher:

```text
plan --environment web --json
start --environment web
status --environment vue3 --services --json
restart --environment vue3 --services
stop --environment vue3 --confirmed
```

`--development` or `--services` narrows a group; omit both for all owned sessions.
Do not combine groups with a positional session, `--all` or adoption flags. Groups
never attach automatically. Processing follows configured order (reverse for
stop/restart). Failure identifies the session and leaves earlier operations applied;
there is no automatic rollback that could kill pre-existing work. Recheck status.
`behavior.stop_scope` must be `selected` when environments exist.

Root routes to local coordinators; local coordinators route to root and their own
workers; workers route only to their coordinator. Root may manage all sessions;
environment coordinators manage only their explicit environment/session ids, on
every route: the helper, `workspace` on PATH, `workspace.sh` and a lifecycle
script run by name (0.13.2). Control-directory
coordinators keep native writes and ordinary shell paths inside that directory. Trusted helpers supply
bounded coordination. Existing Codex audit-mode recommendations still apply;
these are tool policies, not OS isolation or complete Codex path containment.

The launcher pins `SESSION_WORKSPACE_SCOPE_JSON`. Never repair/export identity
manually. Since 0.13.2 it holds only the pane's own scope: its environment, the
root orchestrator's name and its own environment entry (for the unbound root,
the environments without a local orchestrator). Adding, changing or removing
another environment leaves running panes working; changing a pane's own
environment entry (its repository, sessions or coordinator) still requires
restarting that environment's sessions. A pane launched by 0.13.1 or earlier
pinned the whole scope and needs one restart after the next environment change.

Environments may sit on linked git worktrees of one repository (keep them out
of dot directories: use `worktrees/web`, not `.worktrees/web`). Their worktrees
share one git common dir, and the policy treats it, and the main checkout that
holds it, as child content: an orchestrator cannot edit them or run a mutating
command against them (`orchestrator.child_write`). A main checkout that holds
the project root or the orchestrator's own cwd stays writable for it; its
`.git` does not. Each environment on a shared repository declares its
`branch`, and Git commands that would write another lane's branch are refused
(`git.lane_ref`, see Lane branches).


## Root-scoped environment orchestrators

Use [workspace-shared-root.json](../../../templates/workspace-shared-root.json)
and its [operating notes](../../../templates/workspace-shared-root.md)
for two masters at `.` with mixed Claude/Codex workers in `component-a` and
`component-b`, root-level service shells, and separate browsers. The executable
fixture is `scripts/fixtures/valid/shared-root-orchestrators-v5.json`.

```json
{"schema_version":5,"environments":[
  {"id":"web","cwd":"component-a","development":["development"],
   "services":["services"],"orchestrator":"sample-master"},
  {"id":"vue3","cwd":"component-b","development":["vue3-development"],
   "services":["vue3-services"],"orchestrator":"sample-vue3-master"}
]}
```

Set both masters' `cwd` to `.`. `sessions[].panes[].runtime` overrides the role
runtime with a declared runtime key or `shell` (v5 only); omission inherits the
role. Harness panes must resolve to agent runtimes, browser panes to `shell`.
Policy is selected by role, regardless of runtime. Codex enforce limitations
remain unchanged.

A root-scoped master retains the root orchestrator shell/edit floor and guard
packs: root edits are allowed, all child checkout mutations and `git push` are
blocked. It routes to its own workers and any other orchestrator; workers route
only to their owning master. The owning environment is pinned in launch scope
identity. `task-new` requires `--meta environment=<own-id>`; `task-assign` checks
that stored metadata and permits only its own workers (it has no `--meta` flag).
`environment=root` is reserved for an unbound root coordinator. Root-scoped
masters share root stores and memory; there is no additional coordination lock,
so users coordinate concurrent root writes. Control-directory policy is unchanged.
Mixed routing is asymmetric: root-scoped masters can address control-directory
masters, but confined masters cannot reply directly to them. Use the unbound root
as relay when configured; without one there is no reverse coordinator route.

Root-scoped masters still cannot run workspace installation, browser MCP config
or shared-store cleanup helpers. In the shared-root template, which has no unbound
root, run those operations from a user terminal outside the harness. Alternatively,
add an unbound root orchestrator to own them. Never unset launcher identity inside
an active pane to bypass policy.

## Tasks, review and knowledge

Scoped task creation requires exactly one `--meta environment=<id>` (`root` for
root coordination). A worker in an environment that has no local orchestrator
(the unbound root runs it) uses `--meta environment=root`, the tag the root uses.
This applies to `task-review`, `task-done`, `task-block` and `task-contract.sh`.
Environments with their own orchestrator still use `environment=<id>`. Under
`peers`, `task-new` needs no `environment` tag. Assignment/done/block/review checks the task's environment via
the configured scheduler grant. Root delegates to local coordinators through messages; coordinator panes cannot
be scheduler assignees or close tasks. Local coordinators create and assign tasks
to their own executor/reviewer pair, then report their results to root through
messages. Cross-environment work uses linked tasks and permitted coordinator messages; shared storage or dependencies do not grant authority.
Unbound existing tasks require deliberate recreation/migration, never auto-retagging.

Reviewed Git targets expose `environment` and owning `orchestrator`. Root delegates
to that owner; approval packets must retain target id, resolved cwd, task, revision
and actual diff. In v5, local coordinators request target AGENTS.md, Git status,
divergence and revision evidence from their executor/reviewer. Their shell reads
remain confined to the control directory; they do not run target-checkout Git
queries themselves. This replaces direct target inspection in the generic
lifecycle instructions. Reviewers independently verify executor evidence.
Context snapshots should use environment-prefixed names and
structured repository bindings; verify handoffs before resuming in a repository.
Memory retains existing shared/per-pane topology. No new memory system, scheduler state machine or chat transport is introduced.

## Services and browsers

V5 rejects duplicate declared service/browser ports. Set the actual application
port in its argv/config too: pane `port` is metadata. Start rejects occupied ports
before launching a new/unlaunched service; existing managed live panes remain
idempotent. Ordinary port status is `listening`/`not-listening`, separately from
pane health. A socket is not proof of application readiness or process ownership.
Application-specific health checks and dependency graphs are not provided.

Use top-level `browsers` instead of `browser` for multiple bindings. Entries use the
existing browser shape with unique session ids, ports and `mcp_server_name` values;
profiles are separated by project and session. Selected browser panes cannot set
their own command/port. An unbound root orchestrator can use
`browser-config --browser service-web` to select an entry for rendering/applying
MCP config. Without an unbound root, use a user terminal outside the harness; the
shared-root template selectors are `services` and `vue3-services`. Singular browser configs retain their
existing profile location. Switching to `browsers[]` changes
`chrome/<project.id>` to `chrome/<project.id>/sessions/session-<sid>` beneath the
existing browser profile base. When the legacy directory exists but a session's
profile does not, doctor emits INFO with a manual copy command. Stop Chrome first;
the command excludes `sessions/` to avoid copying a destination back into itself.
Doctor never moves data or changes the selected profile.

## Shared services (0.14.0)

An unbound session of service shells (a database, cache, mail catcher, plain
shell) can serve several environments. List it in each environment that uses it:

```json
{"id":"web","cwd":"component-a","development":["dev-web"],"services":["service-web"],
 "orchestrator":"sample-web-master","shared_sessions":["shared-services"]}
```

`shared_sessions` names configured sessions that no environment owns and that
hold only service shell panes, in an environment with an orchestrator. Several
environments may list the same session. That environment's orchestrator may
start a shared pane, one or more at a time, with `start shared-services --pane
NAME` (a running pane is kept). It may not stop, restart or reconcile a shared
session, or start it whole: `stop`, `restart` and `reconcile` are refused under
`routing.shared_stop`, and a whole-session `start` under `routing.scope`. The
root coordinator, the user and the pane's idle watcher (`idle_stop_minutes`)
stop it, so a service another environment still uses never goes down under it.
`workspace status` shows `started by:` (JSON `started_by`) for a pane launched
from a harness pane, so you can see which environment brought it up. A dev
server serves one checkout: keep it in its environment's own `services`
session on its own port, not in a shared one.

## Lane branches (0.15.0)

Environments on linked worktrees of one repository (or a worktree and its main
checkout) share every ref, the repository config and the stash. Each such
environment declares the one branch its executor works on:

```json
{"id":"web","cwd":"worktrees/web","development":["dev-web"],"services":["service-web"],
 "orchestrator":"sample-web-master","branch":"lane/web"}
```

Every environment on a linked worktree requires a `branch`. A primary checkout
also requires one when another configured environment shares its Git directory.
All declared branches must be unique. An orchestration target in that environment must use it as its
`work_branch`. It is part of the environment's pinned entry, so changing it
restarts only that environment's panes.

In that environment's executor the hook applies `git.lane_ref`:

- It may create, reset (`checkout -B`, `switch -C`, `branch -f`, `update-ref`)
  and set the upstream of only its branch, deletes no branch, and switches
  only to its branch or a detached HEAD (`git switch --detach REV` to inspect
  another revision).
  Restoring files (`git checkout REV -- PATH`, `git restore`) is unaffected.
- Commands that write the current branch (`commit`, `merge`, `rebase`,
  `reset`, `pull`, `cherry-pick`, `revert`, `am`, `bisect`) need its branch or
  a detached HEAD checked out.
- `git push REMOTE BRANCH` (or `HEAD`, `HEAD:BRANCH`) is the only push: no
  force, leading `+`, delete, `--all`, `--mirror`, `--tags`, URL, or bare push.
- `fetch` and `pull` may write only remote-tracking refs or its branch.
- Refused outright: `tag`, `stash` (except `list`/`show`), `worktree` (except
  `list`), notes, replace and reflog writes, config and remote writes,
  `symbolic-ref` writes, `gc`, `prune`, `filter-branch`, `rebase
  --update-refs`, `-c`/`--git-dir`/`--work-tree`, and `GIT_*` variables.
  Subcommands outside the reviewed list (aliases included) are refused; spell
  the subcommand out.

Every orchestrator is refused Git commands that would write a declared lane
branch (`branch -D`, `checkout`, `switch`, `update-ref`, a fetch refspec, rebasing
it); reading and merging a lane branch stay allowed. Lanes do not
deploy: their executors cannot write the release branch. Merge lane branches
into it in the main checkout, by hand or, when that checkout is the project
root, through the root coordinator (which still cannot push).
These are argv rules: a script or build tool can still run Git, and a
`rebase.updateRefs` config still applies, so keep release branches protected
on the remote.

## Worker names (0.16.0)

An environment's executor and reviewer may leave out `name`:

```json
{"id":"dev-web","name":"${PROJECT_ID}-dev-web","panes":[
  {"name":"${PROJECT_ID}-web-master","role":"master","cwd":"control-web"},
  {"role":"executor","cwd":"worktrees/web"},
  {"role":"reviewer","cwd":"worktrees/web"}]}
```

The engine names them `<project.id>-web-executor` and
`<project.id>-web-reviewer`. The coordinator picks a label for the work at
hand, and the engine builds the names from it:

```text
workspace label web            # show the label and the worker names
workspace label web auth       # <project.id>-web-executor-auth, -reviewer-auth
workspace label web --clear    # back to <project.id>-web-executor, -reviewer
```

A label starts with a lowercase letter or digit and contains 1–24 characters
from `a-z`, `0-9` and `-`. It is kept in the project
state file `labels.json`, so the names survive restarts until the label is
set again. The engine sets it under the project lock when every worker whose
name would change is stopped. For an on-demand worker use `workspace stop SESSION --pane NAME --confirmed`.
For an always-on worker, check `behavior.stop_scope` and stop the containing session before relabeling.
Start the session again after relabeling if it was running. The engine validates the new names so they
stay unique. An environment coordinator labels only its own
environment (`routing.scope`); the root coordinator and the user may label
any. Workers cannot (`coordination.write`). A name written in the config is
never changed, and a worker with one is not labeled.

The policy finds a coordinator's workers by environment and role, never by
name, so a label grants nothing. Run records, session-chat queues, scheduler
assignments and per-pane memory are kept by pane name, so relabel between
tasks: work queued for the old name stays with the old name.

## Peer orchestrators (schema 6)

Use this shape when several orchestrators work in parallel on the same
checkouts. Each orchestrator is a copy of one declared orchestrator session.
Each owns the workers it starts. No orchestrator controls another's workers.
A checkout has no fixed executor or reviewer pane. An orchestrator starts
executors and reviewers for a checkout when it has work for them.
Start from `templates/workspace-peers.json` and its notes in
`templates/workspace-peers.md`.

```json
{"schema_version":6,"peers":{"session":"development"},
 "environments":[
  {"id":"web","cwd":"component-a","services":["web-services"],"executors":"many"},
  {"id":"vue3","cwd":"component-b","services":["vue3-services"]}],
 "sessions":[
  {"id":"development","name":"${PROJECT_ID}-development","panes":[
    {"name":"sample-master","role":"master","cwd":"."}]}]}
```

The usual project, roles, runtimes, stores, harness and service sessions are also
required. The config requires `harness.enabled`. It lists no workers and no extra
orchestrators.

### What the config may contain

- `peers.session` names one declared session. It has exactly one pane: the
  harness orchestrator role, `cwd` at the project root, not optional, no `launch`.
  The session uses the `standard` layout and does not set `retain_layout`.
- No other declared pane has the orchestrator, executor or reviewer role.
- `peers.limits.orchestrators` (integer, 1 or more) caps orchestrator sessions,
  the declared one included. `peers.limits.workers_per_orchestrator` (integer,
  1 or more) caps the workers one orchestrator owns. Without a limit there is none.
- `environments[]` has no `orchestrator` and no `shared_sessions`. `development`
  may be left out and must be empty if present. `services` and `branch` work as
  in v5. `executors` is `"one"` (default) or `"many"`.
- No declared session id may be `<peers.session>-<digits>`.
- `env.groups.*.values` must not set `XDG_STATE_HOME`. The engine pins it.
- `orchestration.targets[].cwd` must equal an environment `cwd`, as in v5.
- A config file that carries `sessions[].instance` or `sessions[].panes[].worker`
  fails to load. Those fields are engine state.

### Orchestrator copies (the user only)

The user starts an extra orchestrator by name. No config edit is needed:

```text
workspace start development-2 [--no-attach]
workspace stop development-2 --confirmed
```

`N` is a whole number from 2 to 999. The copy is session `<id>-N`, tmux session
`<name>-N` and pane `<pane>-N`. `workspace start` and `workspace start all`
never start a copy, and `reconcile all` skips copies that are not running.
Stopping an orchestrator session, declared or a copy, ends all its workers.
The workers live in its tmux session. The engine removes their records.
Restarting a copy drops its workers' records. An orchestrator cannot start,
stop, restart or reconcile an orchestrator session (`orchestrator.peer_lifecycle`).
`peers.limits.orchestrators` limits the copies:

```text
  [limit] development-3 — peers.limits.orchestrators is 2 and 2 orchestrator session(s) are recorded
```

### Workers

An orchestrator starts its own workers. The user may do it too and then names
the owner:

```text
workspace start --checkout web --role executor [--label auth] [--show] [--no-attach]
workspace start --checkout web --role reviewer
workspace stop --worker NAME --confirmed
workspace show NAME
workspace hide NAME
```

- `--checkout ID` is a declared environment id. `--role` is `executor` or
  `reviewer`. `--label L` matches `^[a-z0-9][a-z0-9-]{0,23}$`.
- The name is `<project.id>-<checkout>-<executor|reviewer>[-<label>]`, for
  example `sample-web-executor` or `sample-web-executor-auth`. The name does not
  contain the owner. A label gives a second worker of the same role.
- The owner is the calling orchestrator. The owner's tmux session must be
  running. Without harness identity (the user), give `--owner PANE`. An
  orchestrator may not use `--owner` (`orchestrator.peer_lifecycle`).
- The worker starts hidden unless `--show`. It prints
  `worker: sample-web-executor (checkout web, role executor, owner sample-master, hidden)` (`shown` with `--show`),
  then `[started]` and `[ready]` as `start SESSION --pane NAME` does.
- `NAME` is the full pane name or the part after `<project.id>-`.
- `start SESSION --pane NAME` and `stop SESSION --pane NAME --confirmed` still
  work for the caller's own workers. The `--pane` stop also finds hidden workers.
- `stop --worker NAME --confirmed` follows the usual busy check. `--force` is the
  user's: an orchestrator that passes it gets `orchestrator.peer_lifecycle`.
- A failed start removes the record it added.
- `workspace label` is refused under `peers`: give the label when you start
  a worker, with `--label`.
- On a config without `peers`, `--checkout` gives
  `ERROR: --checkout needs a schema-6 config with peers`. If the owner's tmux
  session is not running, the error is `ERROR: the tmux session of <owner> ("<name>") is not running; start it first: workspace start <session id>`.

### `[held]`, `[limit]` and `[kept]`

| Line | Exit | Meaning |
|---|---|---|
| `[started]`, `[ready]` | 0 | The worker started. |
| `[kept]` | 0 | The caller's own worker of that name already runs. |
| `[held] <session> / <name> — owner X` | 3 | Another orchestrator owns that worker. Nothing changed. Also returned for stop, show and hide of another owner's worker. |
| `[held] ... — vue3 runs one executor at a time: sample-vue3-executor, owner sample-master` | 3 | The checkout has `executors: "one"` and another executor runs there. |
| `[held] ... — task t-1 was assigned to it by sample-master and is not finished; owner sample-master` | 3 | The name has unfinished scheduler work from another owner. Unread queue rows read `N unread message(s) from SENDER in PATH; owner SENDER`. |
| `[limit] <session> / <name> — peers.limits.workers_per_orchestrator is 1 and <owner> already owns 1` | 1 | A configured limit is reached. |

Held work is not lost. Ask the holder to finish it or to stop the worker, or
pick another label.

### Ownership rules

The engine refuses at the verb. The strict-v1 hook refuses on every route:
the helper, `workspace` on PATH, `workspace.sh` and a lifecycle script run by name.
These are the rule ids (an orchestrator is the caller unless it says otherwise):

| Rule | Refuses |
|---|---|
| `routing.owner` | Addressing, assigning to, stopping, showing or hiding a worker another orchestrator owns. A worker addressing anyone but its owner. |
| `task.scope` | `task-assign` on a task whose `assigner` is another orchestrator. A worker `task-review`, `task-done` or `task-block` on a task whose `assigner` is not its owner, that does not name the worker as assignee or reviewer, or whose reviewer is its assignee. `task-assign --reviewer` equal to the assignee. |
| `coordination.message_read` | A worker reading a delivered message that is not between itself and its owner. |
| `orchestrator.peer_lifecycle` | Start, stop, restart or `reconcile --apply` of an orchestrator session. A bare `start` or `start all`. `--force`. `--owner`. |
| `orchestrator.self_stop` | Stop or restart of the caller's own session, as before. |
| `orchestrator.tmux` | Raw tmux except the read verbs (`list-panes`, `list-windows`, `list-sessions`, `list-clients`, `display-message`, `capture-pane`, `show-options`, `show-window-options`, `show-environment`, `has-session` and their short forms, and bare `-V`). Any word containing `;`, `$`, a backslash, a backtick or `#(`, which also refuses a `\;` chain. A format modifier (`#{E:...}`, `#{T:...}`, `#{S:...}`, `#{s/.../...:...}` and any other `#{...:...}`). A `tmux` word in a segment run by `eval`, `xargs`, `find`, `parallel`, `watch`, `script`, `expect`, `su`, `sudo`, `doas`, `ssh`, `at`, `batch`, `awk` (and `gawk`, `mawk`, `nawk`), `sed`, `busybox`, `make`, an editor (`vi`, `vim`, `nvim`, `ex`, `emacs`), `tclsh`, `wish` or a process wrapper (`timeout`, `nice`, `setsid`, `stdbuf`, `flock`, `ionice`, `chroot`, `caffeinate`, `unbuffer`, `nohup`, ...); in a command whose shell or interpreter reads its code from a pipe, a here-string or a here-document; in the inline code of a shell (`sh -c`, `bash -lc`, ...) or an interpreter (`python3 -c`, `perl -e`, `node --eval`, `php -r`, `osascript -e`, any version suffix); or in a `git -c` value. A script file's arguments are data, so a message that mentions tmux is allowed. Tmux's own leading options (`-L`, `-S`, `-f`, `-c`, `-T`, `-2`, `-u`, `-v`, `-N`, `-l`, `-C`, `-D`) are skipped. |
| `orchestrator.state_write` | The engine owns `<state home>/session-workspace`. Scheduler helpers own `tasks/` under the scheduler store selected by `stores.pin`, including when all workers are stopped. Each task's `assigner` identifies its owner. The rule refuses direct edits and shell mutations inside either directory. It also refuses shell mutations against their parent directories below the project root or home directory. A refusal names the operand when its expansion could reach a protected path. Reads can discard output through `/dev/null`. |
| `identity.override` | A command that runs a workspace route and sets or unsets `SESSION_WORKSPACE_*`, `SESSION_CHAT_PANE_NAME`, `KNOWLEDGE_PANE_NAME`, `TMUX`, `TMUX_PANE`, `TMUX_TMPDIR`, `XDG_STATE_HOME`, `HOME`, or a variable that changes what the engine runs (`PATH`, `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`, `IFS`, `GLOBIGNORE`, `BASH_FUNC_*`, `LD_*`, `DYLD_*`, `PYTHON*`, `PERL5LIB`, `PERL5OPT`, `PERLLIB`, `RUBYOPT`, `RUBYLIB`, `NODE_OPTIONS`, `NODE_PATH`, `JQ_LIBRARY_PATH`), or exports a shell function (`export -f`, `declare -fx`, `typeset -fx`, or `set -a` / `set -o allexport` before a definition), which replaces a command the engine runs by name. Applies to every role. |

These rules classify commands; they keep an orchestrator from acting on another
owner's workers by mistake, or by an ordinary command. They do not contain an
orchestrator that builds a command at run time (for example a program name
assembled from parts in `python3 -c`, a script file it wrote, or code piped
into a shell). Treat peer
orchestrators as agents you trust with the project, not as isolated tenants.
| `orchestrator.child_write` | Writes in any `environments[].cwd`. Every environment `cwd` is child content, whether or not a worker runs there. |

A worker may run no lifecycle route, `show` and `hide` included
(`coordination.write`). Shared-store cleanup helpers
(`tasks-clean.sh`, `messages-clean.sh`, session deletion) stay available to every
peer orchestrator and act on the stores of all of them.

The engine checks `SESSION_WORKSPACE_PANE_NAME` against the project’s pane
marker on `$TMUX_PANE`. The marker can supply a missing name. Conflicting
names produce `ERROR: caller identity does not match this pane`.

A pane claim binds to this workspace through a matching
`SESSION_WORKSPACE_CONFIG`, `SESSION_WORKSPACE_PROJECT_ROOT`, or tmux project
marker. The engine resolves the name against the current config under the project
lock. Orchestrator, executor, and reviewer panes keep their configured roles.
Service panes follow the user lifecycle rules. If the claim or marker cannot
resolve to a configured pane, the command exits 1 and reports
`ERROR: harness identity <name> is not a pane of this workspace; nothing was changed`.
A plain terminal or a caller from another project follows the user rules.

An idle watcher uses the watched service’s pane name and tmux pane ID when it
requests a stop. The engine checks the current role and the expected pane ID.
The service can therefore stop when idle after its starter exits. A replacement
with a different pane ID keeps running.

A refused orchestrator gets
`ERROR: orchestrator.peer_lifecycle: ...` on stderr and exit 1. A worker pane
that runs a mutating verb gets `ERROR: orchestrator.peer_lifecycle: worker pane <name> may not <verb>`.

### Pinned identity and restarts

The launcher pins `SESSION_WORKSPACE_SCOPE_JSON` for each pane. A worker holds
`{"environment":"<checkout>","own":{<its environment entry>},"owner":"<owner pane>"}`.
An orchestrator holds `{"environment":null,"peer":"<its own pane name>"}`. The
engine also exports `XDG_STATE_HOME` (the launcher's state home) to every pane,
so the hook and the engine read one state file. A relative `XDG_STATE_HOME` is
ignored and the state home is `$HOME/.local/state`.

- Starting or stopping an orchestrator or a worker changes no other pane's
  pinned values and needs no restart.
- Changing an environment entry in the config still needs a restart of the panes
  that pin it.
- A worker pins its owner at launch. If the state file changes so that the
  worker's record names another owner, every tool call of that worker is refused
  (`identity.scope`) until you restart it. If its record disappears, the refusal
  is `identity.pane`.

### State file and hidden workers

The engine writes `${XDG_STATE_HOME:-$HOME/.local/state}/session-workspace/<project.id>/instances.json`
under the project lock. Do not edit it. The config loader expands it: copies and
workers appear as concrete sessions and panes in `plan`, `status` and the hook.
The loader drops, without an error, a file that is a symlink or not an object, a
record of the wrong type, an unknown checkout, a role other than
`executor` or `reviewer`, a bad label, an unknown owner and a duplicate.
So check the plan after a change. Mutating verbs remove stale records (the pane
or session is gone) before and after their work, but only when the tmux scan
answered. After you kill every session, records stay until the next mutating
verb finds a running server. Read-only verbs never write.

A hidden worker lives alone in its own window of its owner's tmux session. The
size of that window is `SESSION_WORKSPACE_HIDDEN_SIZE`, `COLSxROWS`, default
`160x48`. Each number is a whole number, at least `40x10`. A bad value gives
`ERROR: SESSION_WORKSPACE_HIDDEN_SIZE must be COLSxROWS, two whole numbers of at least 40x10 (got "...")`
and exit 1 before anything is created.

- `workspace show NAME` joins the pane into the orchestrator's window and
  reapplies the session's standard layout. `workspace hide NAME` moves it back out.
  The pane id and the process stay the same. Both are idempotent.
- Output: `  [shown] S / N — %id — now a pane of the orchestrator's window` and
  `  [hidden] S / N — %id — now in a window of its own`. Already in that state:
  `  [shown] S / N (already)` or `  [hidden] S / N (already)`, exit 0.
- On a config without `peers`, `show` and `hide` give `ERROR: workspace show needs a schema-6 config with peers` (`hide` for `hide`), exit 1.
- A worker that is not running gives `  [absent] S / N — not running; start it with: workspace start --checkout ... --role ...`
  and exit 1. An unknown name gives `ERROR: no worker "X" (workers: ...)` and exit 1.
  If tmux refuses the move, the exit is 1 and the record stays unchanged.
- Only the owner or the user may show or hide a worker. Another orchestrator gets
  `[held]` and exit 3.
- Hidden or shown, a worker keeps its name, its pinned identity and its rules.
  Hidden workers are windows of the owner's tmux session, so session-wide tmux
  commands and `tmux kill-window` affect them.

### Registry fields

Consumers read fields. They never parse pane names.

- `workspace plan --json` has top-level `peers` (`session`, `limits`; `limits` is
  `{}` when absent) and `workers: [{name, role, checkout, owner, visible, running, session}]`.
  `role` is `executor` or `reviewer`. `running` is `null` unless you pass
  `--running`. A TARGET filters `workers[]` to that session. A worker's pane row
  also carries `worker: {checkout, role, label, owner, visible}`, and a session row
  carries `instance`.
- `workspace status --json` gives a worker's row
  `worker: {name, role, checkout, owner, visible, running}`. `visible` comes
  from tmux while the pane runs.

### Scheduler and reviewed orchestration under peers

- `task-new` needs no `environment` tag. Task scope follows the owner: an
  orchestrator assigns only to its own workers, and a worker's transitions need
  the owner as `assigner` (`task.scope`).
- An orchestrator's workers are the registry rows it owns. Route peers are all
  other orchestrator panes.
- `orchestration.targets[]` rows in the plan carry `environment` and have
  `executor`, `reviewer` and `orchestrator` set to `null`. The orchestrator picks
  its own workers on that checkout. It reads `status --json` rows whose
  `worker.owner` is its own pane and whose `worker.checkout` equals the target's
  `environment`. It starts missing ones with `start --checkout`.

### Limits of the model

- These are argv rules on reviewed routes. They are a guardrail, not isolation.
  A root-scoped orchestrator keeps a free shell. Inline interpreter code
  (`python3 -c`, `sh -c`) is not inspected, so it can still run tmux or write files.
- Several orchestrators share the project root. Write coordination for shared
  root files is a user rule.
- There is no per-checkout runtime override and no `read_paths` for workers the
  engine starts. They use the role's runtime and settings.
- There is no label verb. Give the label at `start --checkout`.
- Run records, session-chat queues, scheduler assignments and per-pane memory are
  kept by pane name. That is why a name with unread messages or unfinished tasks
  from another owner is `[held]`.
- `workspace doctor` has read-only `peers.state` and `peers.tmux` checks.

### Migration and rollback

From schema 4 or from a schema-5 shared-root config:

1. Back up the current config and record its running sessions with
   `workspace status --json`. Upgrade both providers to 0.17.0 or later.
   Finish assigned work, reviews and active turns, and read each pane's queued
   messages. From a user terminal, stop the sessions you will migrate while
   their current config is active.
2. Set `schema_version` to `6` and enable the harness. For a schema 4 config,
   add an `environments` entry per checkout (`id`, `cwd`, `services`).
3. Remove the environment `orchestrator`, `shared_sessions` and `development`
   fields. Add `peers.session` and, if wanted, `executors` and `peers.limits`.
   Remove `XDG_STATE_HOME` from `env.groups.*.values`. Set a custom state home in the launcher.
4. Give the peers session one required orchestrator pane at the project root.
   Omit its `launch` field. Use the standard layout and omit `retain_layout` or
   set it to `false`. Remove declared executor and reviewer panes. Check that
   each role's runtime and default read access suit its workers across checkouts.
5. Run `workspace doctor` and `workspace plan`. Use `workspace start SESSION`
   with the ID in `peers.session` to start the declared orchestrator.

A v6 config without `peers` needs only the version number and behaves as v5.

To roll back, finish worker activity and read queued messages. From a user
terminal run `workspace stop --confirmed` while schema 6 is active. This stops
all configured project sessions, including services. Confirm the intended sessions
have stopped with `workspace status --json`. Restore the previous config, review
its plan and start the sessions recorded before migration to restore their
pinned identities. Older releases ignore `instances.json`.

## Removed Jev integration

Session-workspace 0.12.0 removed the optional Jev diagnostic helper. A v5 config
that still has top-level `integrations`, `environments[].jev`, or `"integrations"`
in `stores.pin` fails validation with a message that names the removed field.
Migration needs only config edits: remove `integrations`, `environments[].jev`,
and the `integrations` store pin. Revoke any Jev credential at the provider
first. Delete the local copy only with separate authorization. Keep the existing
paid-call accounting and evidence records.

## Migration / rollback

Upgrade both providers before opting into v5; old releases reject it. Keep the old
config, create required directories, inspect plan, start selected environments.
Never migrate in-flight approvals to a different repository. Roll back by stopping
only introduced sessions, restoring old config and restarting affected identities.
Jev removal in 0.12.0 needs only the config edit above, and no task-store migration.

To merge two v4 configs that share one root, follow these steps. Merge the sessions
and keep the pane names. Choose one project id and `stores.base`. Add the environments
and pane runtimes. Then restart all sessions to establish the new identity. Stop the retired second project
with its old config first to release port-registry entries owned by its project id.
Keep both old configs for rollback; stop the merged sessions before restoring them.
