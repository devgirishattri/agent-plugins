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
uses the configured orchestrator role and has a distinct control directory outside
all child repositories (for example `control-web`). Exactly one root orchestrator
remains at workspace root. Without a local coordinator, workers route to root.
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
locals manage only their explicit environment/session ids. Local native writes and
ordinary shell paths stay inside their control directory. Trusted helpers supply
bounded coordination. Existing Codex audit-mode recommendations still apply;
these are tool policies, not OS isolation or complete Codex path containment.

The launcher pins `SESSION_WORKSPACE_SCOPE_JSON`. Never repair/export identity
manually. Changing repository/session/coordinator bindings requires restarting
affected sessions; Jev feature toggles are excluded from this scope identity.

## Tasks, review and knowledge

Scoped task creation requires exactly one `--meta environment=<id>` (`root` for
root coordination). Assignment/done/block/review checks the task's environment via
the configured scheduler grant. Root delegates to local coordinators through messages; coordinator panes cannot
be scheduler assignees or close tasks. Local coordinators create and assign tasks
to their own executor/reviewer pair, then report their results to root through
messages. Cross-environment work uses linked tasks and root-mediated messages; shared storage or dependencies do not grant authority.
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
Memory retains existing shared/per-pane topology. No knowledge data goes to Jev;
no new memory system, scheduler state machine or chat transport is introduced.

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
their own command/port. Root uses `browser-config --browser service-web` to select
an entry for rendering/applying MCP config. Singular browser configs retain their
existing profile location.

## Optional removable Jev

The guide-only helper is explicit, never called by lifecycle, hooks, policy,
scheduler, chat or recall. Diagnostic synthetic results are promising; workload
benefit is unproven. The failed acceptance-criterion checker is excluded. No
collection, remediation, retries, command generation or authorization is automated.

```json
{"integrations":{"jev":{"enabled":false,"mode":"shadow",
  "model":"jev-1.13.0","credential_file":".agent-workspace/jev.local.key"}}}
```

Absent/false performs no credential, packet, budget-store or network reads. A
credential is a gitignored owner-owned mode-0600 regular file containing one raw
key, never JSON/argv/messages or generic pane secret delivery. Enabled but missing
credentials/adapter/API/store or corrupt accounting returns unconfigured or unavailable and leaves
ordinary work intact. `workspace.sh jev --status` reads configuration only;
`ready_unverified` does not prove account access. Plan/status/doctor are non-billable.

For explicit evaluation, pin `integrations` in `stores.pin`, use an env group with
`pin_to_session: true`, and configure non-secret inherited tunables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SESSION_WORKSPACE_JEV_MAX_REQUESTS` | `0` | Cumulative workspace-store request ceiling, 0–10000; zero prevents paid calls |
| `SESSION_WORKSPACE_JEV_TIMEOUT_MS` | `5000` | Single-request timeout, 1–15000 ms; no retries |

The launcher supplies `SESSION_WORKSPACE_INTEGRATIONS_HOME` and creates the pinned
operational directory only when enabled. Helpers consume it and never derive/export
a replacement. Env-group changes require restart; the feature switch is read each
call. Calls with `--environment` additionally require that environment's `jev: true`.
Local coordinators must select their own environment. Root may call without an
environment for workspace diagnostics; only the global enabled switch gates that
case. Global off always wins.

Only with explicit sanitized-input authorization and a spending ceiling, invoke:

```text
bash <PLUGIN_ROOT>/scripts/workspace-jev.sh --environment web --packet <absolute-packet.json> --sanitized
```

The packet has only string fields `surface` (`chat`, `context`, `workspace`,
`harness`), `current_observation`, `background`; max 4096 bytes. Remove identifiers,
secrets and unrelated content manually. Screening is not an anonymization guarantee.
Stage packets inside the workspace root; locals should use their control directory.
Symlink traversal is rejected. Active harness callers must be coordinators; locals select their own environment
and a readable packet. Fixed HTTPS transport refuses proxies and redirects. Enabling
configuration does not authorize genuine log uploads.

`shadow` returns usage/provenance without a guide; `advisory` can return an existing
skill identifier or unknown at the fixed evaluated 0.9 selected-probability cutoff.
Both spend budget. Locked/fsynced reservations precede transmission; every attempt,
including timeout/failure, permanently consumes a slot and a conservative 65536-token
allowance. This is a request bound, not an invoice guarantee. The ledger holds only
digests/reservations, no payload/key. Identical packet/config revisions are not
retried. No cache is used. Preserve accounting across restart/re-enable; never remove
it to reset the ceiling. Late results from a changed configuration are discarded;
an already transmitted request cannot be unsent.

To remove: disable, remove `integrations.jev`, environment Jev flags and the credential
reference, then optionally remove the dedicated credential. Preserve accounting and
experiment evidence. No SDK/background service needs uninstalling. Adapter/catalog
are isolated from core; missing adapter reports unavailable. No tasks or approvals
require model output.

## Migration / rollback

Upgrade both providers before opting into v5; old releases reject it. Keep the old
config, create required directories, inspect plan, start selected environments.
Never migrate in-flight approvals to a different repository. Roll back by stopping
only introduced sessions, restoring old config and restarting affected identities.
Removing Jev requires no workspace-plugin downgrade or task-store migration.
