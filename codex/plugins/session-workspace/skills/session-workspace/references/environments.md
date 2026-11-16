# Independent environments (schema v5)

V5 retains v1-v4 support. Start with `templates/workspace-multi-environment.json`.
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
root coordination). Assignment/done/block/review checks the task's environment via
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

`branch` is required when the environment's checkout shares its git
repository with another checkout, optional otherwise, and unique across
environments. An orchestration target in that environment must use it as its
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
