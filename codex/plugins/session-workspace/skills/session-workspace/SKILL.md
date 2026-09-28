---
name: session-workspace
description: When and how to use session-workspace lifecycle commands, its strict-v1 multi-agent harness, and schema-v4 reviewed Git orchestration. Use before workspace/harness commands or workspace-orchestrator so you understand the config model, safety gates, and provider-neutral coordination boundary.
---

# session-workspace: config-driven tmux workspace engine

`session-workspace` is a shared engine that replaces hand-maintained
per-project `workspace.sh` launchers. Instead of six near-identical scripts
drifting independently, one engine reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it.

**Current status: fully implemented.** Config load/validation, mutation-free
planning, runtime argv/env construction, and tmux session/pane lifecycle
(create, adopt, reconcile, stop, restart) are all live and enforced — this
is not a scaffold.

## Commands

| Command | Purpose |
|---|---|
| `/workspace-doctor` | Read-only dependency/config health check |
| `/workspace-plan` | Dry-run plan (human + JSON); mutates nothing |
| `/workspace-start` | Bring up sessions/panes/agents/services (idempotent) |
| `/workspace-status` | Current lifecycle state; mutates nothing |
| `/workspace-stop` | Tear down sessions/panes (destructive, needs `--confirmed`) |
| `/workspace-restart` | Stop then start (destructive, confirmation implicit) |
| `/workspace-reconcile` | Dry-run by default; `--apply` repairs drift; `--adopt --confirmed` claims unmanaged panes |
| `/workspace-install` | Install/refresh the machine-wide `workspace` dispatcher on PATH; no config, no tmux, idempotent |
| `/workspace-browser-config` | Render/apply project MCP entries for the configured browser |
| `/harness-status` | Read-only: is the opt-in harness active (mode/profile/roles/gates), and does this pane's engine identity match the plan |
| `/harness-doctor` | Read-only harness health: config validity, activation, hook registration, python3, live identity match |
| `$session-workspace:workspace-orchestrator` | Schema-v4 status/plan/dispatch/review/commit/push/deploy lifecycle using configured executor/reviewer pairs |

## Configuration model (enforced)

A project opts in by creating `.agent-workspace/workspace.json`
(`schema_version: 1`, `2` for the optional harness, `3` for shared guard packs,
or `4` for reviewed orchestration) describing:

- `project` — id/display name/root
- `runtimes` — named launch profiles (e.g. `claude`, `codex`), replacing any
  free-form custom-command entry
- `roles` — per-role runtime, optional `agent.{model,effort,profile}`,
  `--add-dir` grants, env group
- `stores` — which coordination stores (`messages`, `scheduler`, `contexts`)
  get exported/session-pinned, plus memory topology (`shared` vs `per-pane`)
- `sessions[].panes[]` — declarative session/window/pane plan, including a
  `split_tree` layout kind for hand-built layouts a named layout can't
  express, and `optional: true` for a pane whose `cwd` may not exist yet (an
  un-cloned child repo) — such a pane is skipped, never launched with a
  wrong/inherited cwd
- `secrets` — an owner-only (mode 0600, git-ignored) env file, gated by
  `secrets.allow` / `secrets.visible_to_roles` / `secrets.on_missing`
- `behavior` — attach/stop-scope/save defaults
- `browser` — optional Chrome DevTools binding: `session_id` plus, when that
  session has more than one pane, `pane_name` naming the single pane that
  receives the Chrome argv (a one-pane session may omit it); pinned MCP
  package, loopback port, and portable derived profile. Only the selected pane
  reports DevTools readiness; siblings keep their own `command`/`port`
- `harness` (schema v2/v3/v4) — opt-in strict-v1 role policy: `enabled`,
  `mode` (`audit`|`enforce`), `profile`, the three semantic `roles`, and
  `gates`, plus optional schema-v3/v4 `guards`; absent or `enabled: false` is a true no-op (for panes whose
  launcher mode is empty — a pane launched under audit/enforce keeps that
  mode and blocks as drift until restarted)
- `orchestration` (schema v4 only) — optional closed `reviewed-git-v1`
  targets. It binds a safe child cwd to its configured executor/reviewer pair,
  named remote, work/release branches, and fixed merge strategy; it accepts no
  commands, scripts, prompts, regexes, or custom gate bypasses.

`workspace.schema.json` in `scripts/` documents this shape, and
`validate-config.sh` enforces it — both structurally (via
`validate-structural.jq`: unknown/missing keys, name uniqueness, env var
naming, permission_mode allowlist, etc.) and against the filesystem (cwd/
symlink escape checks, the secrets file's location/mode/ownership/
git-ignore state).

### Secret delivery

From 0.8.0, `secrets.allow` accepts strings and closed objects with required
`key` and `roles` fields, for example
`["SHARED_TOKEN", {"key":"MCP_TOKEN","roles":["master"]}]`.
Strings inherit `secrets.visible_to_roles`; objects receive its intersection
with their own `roles`. The global list is always a ceiling. Omitted/empty
global visibility or empty per-key roles grants nothing. Role names reference
the configured `roles` map, not fixed semantic role labels. Unknown roles,
duplicate object role names, duplicate keys (exact, case-sensitive across both
forms), invalid identifiers, unknown object fields, and missing/null object
fields fail validation. Keys match `^[A-Za-z_][A-Za-z0-9_]*$`.

Both secret-file delivery and the explicit single-key lookup authorize before
resolving values. `on_missing` applies only to entitled keys; a missing
master-only token cannot warn or block executor delivery. Lookup denials name
the allowlist, global ceiling, or per-key roles rule without revealing value
presence. Plan reports `secret_keys_by_role` and each pane's `secret_keys` as
names only. Doctor reports effective names by role and keys with no recipient;
for object/mixed configs its file checks cover only effective keys and name
affected roles. Legacy string-only doctor file checks still scan every key.
Doctor is workspace-wide and diagnoses the file; caller environment overrides
still apply at delivery. The authorized `secret-value` command intentionally
returns the resolved value; never use it to populate reports or logs.

Migration: existing unique-key string configs need no change. Before adding a
role to global visibility, convert keys that role must not receive to object
entries in the same edit. Update both providers, inspect plan/doctor, then
restart affected panes and MCP processes. No `schema_version` or store migration
is required. Restore a safely restricted string-only config before downgrading;
never flatten object entries into strings under a widened global list. This
controls workspace delivery, not same-user filesystem access or independently
inherited credentials.

A secret is delivered to exactly one pane's spawned PROCESS environment via
a private, single-use, mode-0600 file: `adapters.sh secret-file` resolves
and gates it (`secrets.allow` / `visible_to_roles` / `on_missing`), writes
`KEY=VALUE` lines to that file, and returns only its PATH — never the
value. The pane's launch script reads that path with shell `read`/`export`
BUILTINS (never `.`/`source`/`eval`, so a value can never be re-parsed as
code), exports each var into that pane's own process environment, and
unlinks the file immediately. Nothing ever goes through `tmux
set-environment` (hidden or plain), `send-keys`, or argv — a hidden tmux
variable is never passed into a new process's environment, and a plain one
is both session-scoped (every later pane would inherit it) and readable by
any pane via `show-environment`.

Non-secret env that a role's `env_group` marks `pin_to_session: true` DOES
use plain `tmux set-environment` on purpose — that path is for coordination
vars a hand-made pane should also inherit, and secrets are excluded from it
by construction.

## The opt-in harness (schema v2/v3/v4)

With `harness.enabled: true` the engine's `PreToolUse` hook enforces an
**immutable strict-v1 floor** keyed on the per-pane identity it exports at
launch (`SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`, `_PANE_NAME`, `_ROLE`,
`_PANE_CWD`, `_HARNESS_MODE`). Relay these consequences when a user hits
them:

- A session not launched by `workspace-start`, a schema-v1 project, or
  `enabled: false` is a true no-op — nothing is gated — as long as the pane
  was not launched under an earlier `audit`/`enforce` mode (stale mode is
  drift and blocks until the configured session containing the pane is
  restarted via `$session-workspace:workspace-restart <session-id>`).
- **Draft files (0.7.1)**: reviewers, executors, and confined coordinators with
  a validated `messages` grant may use native edit tools to create, revise, and
  delete `<messages-grant>/drafts/<pane-name>/<safe-name>.md` or `.txt`.
  The stem starts with an ASCII letter/digit, uses only ASCII letters/digits,
  `.`, `_`, `-`, and is at most 128 characters. Resolve the grant and pane name
  from the validated plan; inherited variables cannot grant access. Only the
  pane's own ordinary single-link drafts are allowed. Transport files, peer
  drafts, queue/archive/ledger state, symlinks, moves, and mixed patches remain
  blocked. Shell staging and cleanup remain blocked, including when the granted
  message store is inside the checkout. Confined coordinators must use native
  reads or trusted helpers for store reads, even inside the checkout. Root
  coordinators retain authority to edit the entire store, including transport
  messages.
  Dispatch with `--reply-to` for a reply, then natively delete your draft only
  after delivered or durable queued success; preserve it after hard failure.
  Claude has no native delete tool and retains its inert draft.
  No grant means no staging exception. Existing reviewer top-level drafts must
  be restaged here; never move or edit transport files. No config/schema migration
  is required. Update both plugins and restart affected agents. Downgrading
  restores the executor staging failure and the reviewer transport-edit flaw.
- **Reviewer**: other native edits remain blocked. Shell remains default-deny
  except one literal read-only command inside its checkout or explicit per-pane
  `read_paths` (no pipes, redirection, `sed`, or ungranted sibling reads), and
  trusted coordination helpers. Use `$session-chat:reply` for verdicts.
  Schema v2–5 reviewers and executors may set `sessions[].panes[].read_paths` to up to 16
  existing files/directories, relative to the project root or canonical absolute
  paths for external repositories. Files grant exact-file access, directories
  grant descendants. Symlink components, parent traversal, overlapping grants,
  configured stores/memory/secrets, provider homes and foreign v5 environments
  are rejected. Recursive symlink-follow options and directory `diff` are denied;
  compare explicit files instead. Restricted ripgrep commands must begin with
  `rg --no-config` so inherited configuration cannot add traversal or execution.
  Explicit preprocessors, `--hostname-bin` and `-z`/`--search-zip` are also denied.
  Update existing reviewer/scoped-read commands when upgrading to 0.6.4; there
  is no config/store migration. These paths affect shell reads and reviewer
  tool workdirs only: they do not grant helper-store access, native Read/Grep/Glob
  permissions, `--add-dir`, or writes. Provider permissions still apply.
  `SESSION_WORKSPACE_READ_PATHS_JSON` is engine-owned launch identity, never a
  user tunable; changes/removal or filesystem drift fail closed in both modes
  for the affected pane. Restore an unavailable path, or update the config
  and restart its session. Plan/status retain unavailable entries for diagnosis;
  other panes and stop remain usable. Launch refuses unavailable read paths.
  Omitted/empty paths keep old behavior.
  Hooks are not an atomic filesystem sandbox against racing same-uid swaps.
- **Message reads (0.10.0)**: executors and reviewers may read a complete
  delivered message addressed to or sent by their validated pane, or an existing
  own draft, using the existing single literal non-Git read grammar. Use the
  quoted `cat '<absolute-path>'` command printed before the incoming body;
  inline truncation is not a task-size limit. Delivered files must sit directly
  in the plan's messages grant, be private owned regular single-link files,
  and have no symlink component or `..` traversal. Parse the generated
  `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md` name against all validated
  pane names; exactly one endpoint pair must match, with this pane at one end.
  Ambiguous or removed peers fail closed. No environment override grants reads.
  Reviewers lose broad message-store and ungranted provider-inbox access.
  Peer files, queue/archive/ledger state and message-store workdirs are denied.
  Recursive reads from ancestors of the store (`rg`, `find`, `du`, recursive
  `grep`, `ls -R`) are denied; name explicit safe subdirectories, not glob
  exclusions. Own-draft native writes and coordinator behavior are unchanged.
  Claude native Read remains ungated; these operand checks do not isolate
  arbitrary program internals or concurrent same-user filesystem changes.
  Update session-chat to 0.17.13 and workspace to 0.10.0, then restart panes.
  No schema/store migration. Rollback restores the executor read failure and
  broader reviewer access.
- **Executor**: explicit per-pane `read_paths` also permit single literal shell
  reads using the reviewer read-command restrictions above. Executor tool workdirs
  must remain inside its checkout; use relative or absolute operands for shared
  docs. Grants never permit writes or composed shell commands outside the checkout.
  From 0.7.1, executors can also read files in the selected `girishattri-plugins`
  version using the same restricted single-command grammar, without `read_paths`.
  This includes skills, commands, references, and scripts as data. Use separate
  `cat <absolute-path>` calls or `rg --no-config`; it grants no cache writes,
  cache workdirs, execution, unselected-version reads, or extra store access.
  This cache-read exception does not change confined orchestrator shell reads. No configuration migration
  is required; update the plugin and restart affected agents. Downgrading restores
  the earlier executor cache-read restriction without changing stores.
  From 0.7.3, reviewers and executors can also read provider-installed skill
  documentation with the same single literal, non-`git` read grammar: Codex
  system skills (`<codex-home>/skills/.system/<skill>/`, only while the
  system-skills marker exists) and user skills (`<codex-home>/skills/<skill>/`,
  `<claude-home>/skills/<skill>/`) whose directory holds a regular `SKILL.md`.
  Files must be regular, single-link, inside that skill directory, with no
  symlink or hidden components (except `.system`). No workdirs, helper
  operands, writes, execution, or other provider-home content. Known limit:
  skills from non-`girishattri-plugins` marketplace plugins stay denied.
  The ordinary in-checkout executor shell floor is unchanged: these restricted
  read rules do not establish recursive traversal confinement for general
  executor commands. Otherwise, edits and shell path operands must stay inside its own
  checkout (the fixed `/dev/null` sink/source is the only exempt operand); inline code (`bash -c`, `python -c`) and sandbox-escape flags
  are blocked; it may only message the orchestrator. Read dispatch files
  with the literal read command above and stage dispatch files in the own-pane draft namespace
  above (writes under `$TMPDIR` are refused by containment).
- **Orchestrator**: cannot edit or run mutating commands against a child
  checkout; routes only to its configured executor/reviewer panes;
  `broadcast` is not available under strict-v1.
- From **0.9.0**, root and confined orchestrators also deny direct remote-mutating
  `gh` commands even without a child filesystem operand. Route mutations to the
  executor. Reviewed reads are `run list/view` (including logs),
  `pr list/view/diff/checks`, `workflow list/view`, `release list/view` with an
  explicit `--repo`/`-R OWNER/NAME`, positional `repo view OWNER/NAME`, and
  `api repos/OWNER/NAME/...` or `api repositories/ID/...` with effective GET.
  API `-f`/`-F`/`--input` require explicit uppercase `--method GET`/`-X GET`;
  file-backed inputs send contents to GitHub even on GET. File paths retain
  confined coordinator containment; stdin inputs are unsupported. The closed
  grammar is reviewed against gh 2.100.0; unknown flags fail closed. Use supported
  `--json`, `--jq` and `--limit` options instead of pipes. Quoted jq `|` and `?`
  are formatting data. Only direct single literal `gh` calls qualify: no aliases,
  extensions, executable paths, inline env assignments, wrappers, shell
  composition, expansions or redirections. Use launch-inherited secrets for
  credentials. Browser flags, command-line host overrides, headers and API caching
  are unsupported; inherited `GH_HOST`/gh configuration remain trusted launch
  environment, not a fixed-host guarantee. Run/PR selectors are numeric. No owner
  allowlist is applied. A literal `gh` operand to a non-data command (for example
  `git log --author gh`) is also conservatively refused.
  Decision rules are `orchestrator.gh_read`, `orchestrator.gh_mutation` and
  `orchestrator.gh_unsupported`; existing containment/integrity rules still apply.
  Executor/reviewer permissions and Git redirects/loops are unchanged. No new
  config key or schema/store migration; update both providers and restart agents.
  Downgrading restores the remote-mutation gap and earlier read restrictions.
  This is an argv guardrail for root and confined orchestrators, not subprocess
  isolation: scripts and stdin-fed interpreters (and root inline code) can still
  invoke gh. Withhold write-scoped orchestrator credentials where remote mutations
  must be impossible. Unclassified MCP calls retain their existing limits.
- From 0.7.4, shared shell path checks include attached short-option values
  and literal operands after `--`, including through accepted wrappers.
  Known `grep`/`rg` pattern and `sort` key/separator values remain data;
  unknown short options receive conservative path checks. Reviewers cannot
  use `sort` output or temporary-directory options. Executor output paths
  must stay in the checkout; orchestrators cannot direct them into a child.
  This remains an argv containment floor, not a complete command interpreter.
  No config or store migration is needed; update and restart affected panes.
  Downgrading restores the attached-option gaps. Keep project guards until
  the combined hook chain has been verified before retiring duplicate checks.
- `sudo`/`doas`/`su`/`runuser`/`pkexec` are refused for every role at any
  wrapper hop, as is any unsupported wrapper option (`exec -a`, `nohup --`,
  `time -o`, `env -S` all fail closed); the accepted `env`/`command`/
  `builtin`/`exec`/`nohup`/`time` forms are enumerated by `parse_wrappers` in
  [harness-policy.py](../../scripts/harness-policy.py).
- Installed helpers must be invoked as one literal
  `bash <selected-cache-path>/scripts/<name>.sh args...` — no env prefix,
  wrapper, chaining, expansion, stale version, or copied script.
- `audit` mode reports `AUDIT by session-workspace strict-v1 [...]` and never
  blocks a *policy* denial (on Claude as one stderr line; on Codex, which
  discards stderr for successful hooks, as one inert top-level
  `systemMessage` JSON object); `enforce` prints `BLOCKED ...` and blocks.
  On Codex the runtime does not expose a per-call shell workdir, so do not
  present Codex `enforce` as complete path containment — `audit` is the
  recommended Codex mode for now.
  Identity/config/drift integrity failures block in both modes — the remedy
  is `$session-workspace:workspace-restart <session-id>` of the configured
  session containing that pane — this kills and recreates ALL of that
  session's configured panes, not just the drifted one — never hand-editing
  the identity variables.
- In schema v3/v4, optional `harness.guards` centralize orchestrator protected
  files, child-directory hops, generic lifecycle reminders, and bounded Stop
  health warnings. Guard changes require a workspace restart because their
  canonical JSON is launcher identity.
- `warn_missing_panes` ignores `optional:true` and shell/service panes.
  Workspace-health diagnostics emit only from the configured orchestrator;
  `branch_ahead` is a neutral local-branch fact, not deploy authorization.
- After a Codex plugin upgrade that changes hook entries, accept/re-trust the
  new session-workspace hook hashes before relying on lifecycle/Stop output.
- Run `/harness-doctor` first when something is unexpectedly blocked.

## Reviewed orchestration (schema v4)

When `orchestration.enabled` is true, use
`$session-workspace:workspace-orchestrator`. The normalized workspace plan is
the sole target map; the orchestrator coordinates and every Git mutation runs
in the target executor. The fixed lifecycle requires correlated explicit plan
approval, user confirmation, scheduler-tracked execution, reviewer-authored
explicit audit approval, and separate commit/push/deploy confirmations. Its
freshness windows come from `harness.gates`. Ledger and session-chat records
are machine-verifiable evidence; user confirmations remain conversational and
must never be described as harness-enforced.

## Safety gates worth relaying to the user

- An unmanaged pane occupying a planned slot is never renamed/respawned —
  the slot fails with guidance until `--adopt --confirmed` is used
  deliberately, and the adoption-candidate details are always shown first
  (even in `reconcile`'s dry-run, without `--apply`).
- A tmux session with the same configured name that this engine did not
  create is never touched — exact `=NAME` targeting only, never a prefix
  match.
- `stop`/`restart` never run without confirmation (`stop` refuses outright
  without `--confirmed`; `restart` implies it).
- `workspace-plan`, `workspace-status`, and `workspace-doctor` are
  mutation-free; don't hesitate to run them freely to check state.

## Schema v5: independent environments and optional diagnostics

Read [references/environments.md](references/environments.md) for named development/
services groups, optional local orchestrators, scoped routing/tasks, multiple browser
bindings, and the fully optional removable Jev diagnostic helper. Versions 1–4
retain their single-orchestrator contract. V5 pins scope identity at launch; never
export it manually. Jev stays off unless configured, and supplies no approvals.

New inherited operational tunables are `SESSION_WORKSPACE_JEV_MAX_REQUESTS` (default
0, cumulative 0–10000 request ceiling) and `SESSION_WORKSPACE_JEV_TIMEOUT_MS` (default
5000, range 1–15000). The optional pinned `integrations` store is launch-inherited
as `SESSION_WORKSPACE_INTEGRATIONS_HOME`. Full data, credential, fallback and removal
contracts are in the reference; do not upload logs merely because it is enabled.
