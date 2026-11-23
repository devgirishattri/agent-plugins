---
name: session-workspace
description: Use session-workspace lifecycle commands, the strict-v1 multi-agent harness, and reviewed Git orchestration. Covers schema 6 peer orchestrators and on-demand workers. Read before workspace/harness commands or workspace-orchestrator.
---

# session-workspace: config-driven tmux workspace engine

Knowledge 0.5 implicit inbox capture requires workspace 0.11.1 or later under
strict-v1. The reviewed helper grammar admits `memory-auto-capture.sh` for
orchestrators/executors with optional `--store PATH` followed by one or more
`--staged FILE` pairs. Each file must pass normal literal-file containment.
Reviewers, batch directories and mutation verbs such as purge remain denied.
An older installed harness refusing capture is a compatibility limitation, not
permission to bypass it. Update/restart the configured harness before retrying.

`session-workspace` is a shared engine that replaces hand-maintained
per-project `workspace.sh` launchers. The engine reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it.

**Current status: fully implemented.** Config load/validation, mutation-free
planning, runtime argv/env construction, and tmux session/pane lifecycle
(create, adopt, reconcile, stop, restart) are all live and enforced — this
is not a scaffold.

## Commands

| Command | Purpose |
|---|---|
| `$session-workspace:workspace-doctor` | Read-only dependency/config health check |
| `$session-workspace:workspace-plan` | Dry-run plan (human + JSON); mutates nothing |
| `$session-workspace:workspace-start` | Bring up sessions/panes/agents/services (idempotent) |
| `$session-workspace:workspace-status` | Current lifecycle state; mutates nothing |
| `$session-workspace:workspace-stop` | Tear down sessions/panes (destructive, needs `--confirmed`) |
| `$session-workspace:workspace-restart` | Stop then start (destructive, confirmation implicit) |
| `$session-workspace:workspace-reconcile` | Dry-run by default; `--apply` repairs drift; `--adopt --confirmed` claims unmanaged panes |
| `$session-workspace:workspace-install` | Install/refresh the machine-wide `workspace` dispatcher on PATH; no config, no tmux, idempotent |
| `$session-workspace:workspace-browser-config` | Render/apply project MCP entries for the configured browser |
| `$session-workspace:harness-status` | Read-only: is the opt-in harness active (mode/profile/roles/gates), which strict-v1 role floor applies (`--probe` decides its cases), which optional guard packs add to it, and does this pane's engine identity match the plan |
| `$session-workspace:harness-doctor` | Read-only harness health: config validity, activation, hook registration, python3, live identity match |
| `$session-workspace:workspace-orchestrator` | Coordinate the reviewed Git lifecycle in schemas 4–6. With peers, use your own workers for the target checkout. |
| `$session-workspace:design-sketch` | Compare interfaces or competing designs from a real caller before implementation |
| `$session-workspace:verification-recipe` | Create or maintain a behavioral recipe, including bounded checks for retries and event orderings |
| `$session-workspace:blast-radius` | Report indirect breakage risks and check the assumptions that make a diff safe |
| `$session-workspace:adversarial-review` | Optional independent review with bounded effort and evidence-based dispositions |
| `$session-workspace:benchmark-check` | Validate comparable measurements, correctness, work counts, and uncertainty |
| `$session-workspace:behavioral-eval` | Assess skill/workflow changes using actual actions and artifacts |
| `$session-workspace:pr-status` | Read-only structured PR blockers, pending checks, and unknowns |

## Configuration model (enforced)

A project opts in by creating `.agent-workspace/workspace.json`. Set
`schema_version: 1`, `2` for the optional harness, `3` for shared guard packs,
`4` for reviewed orchestration, `5` for independent environments, or `6` for peer orchestrators. The config describes:

- `project` — id/display name/root
- `runtimes` — named launch profiles (e.g. `claude`, `codex`), replacing any
  free-form custom-command entry
- `roles` — per-role runtime, optional `agent.{model,effort,profile}`,
  `--add-dir` grants, env group
- `stores` — which coordination stores (`messages`, `scheduler`, `contexts`)
  get exported/session-pinned, plus memory topology (`shared` vs `per-pane`)
- `sessions[].panes[]` — declarative session/window/pane plan.
  - A `split_tree` layout kind covers hand-built layouts that a named layout
    can't express.
  - `optional: true` marks a pane whose `cwd` might not exist yet (an
    un-cloned child repo). The engine skips such a pane. It never launches the
    pane with a wrong or inherited cwd.
- `secrets` — an owner-only (mode 0600, git-ignored) env file, gated by
  `secrets.allow` / `secrets.visible_to_roles` / `secrets.on_missing`
- `behavior` — attach/stop-scope/save defaults
- `browser` — optional Chrome DevTools binding: `session_id`, a pinned MCP
  package, a loopback port, and a portable derived profile.
  - A session with more than one pane also needs `pane_name`. It names the
    single pane that receives the Chrome argv. A one-pane session can omit it.
  - Only the selected pane reports DevTools readiness. Siblings keep their own
    `command`/`port`.
- Service panes (the browser, dev servers) also start and stop on their own:
  `workspace start SESSION --pane NAME` and
  `workspace stop SESSION --pane NAME --confirmed`. An optional pane
  `idle_stop_minutes` stops an unused one, and `start --pane` names the PID
  holding a taken port instead of colliding. [Starting selected panes](../workspace-start/SKILL.md)
- Executor and reviewer panes marked `"launch": "on_demand"` (active strict-v1
  harness, standard layout) stay down on a full start. The orchestrator starts
  one with `workspace start SESSION --pane NAME`. Every check must show the
  agent's input line for `SESSION_WORKSPACE_AGENT_READY_SETTLE_MS` milliseconds
  (default `1500`). Set it to `0` to accept the first input line.
  `SESSION_WORKSPACE_AGENT_READY_TIMEOUT` sets the total readiness wait in
  seconds (default `120`). [Worker readiness](../workspace-start/SKILL.md)
  The orchestrator closes the worker with `workspace stop SESSION --pane NAME
  --confirmed`, which leaves a busy worker running. The orchestrator may not
  stop or restart the session holding its own pane (`orchestrator.self_stop`).
  - The idle watcher reads these variables when `start` arms it, so a change
    applies from the next start. `SESSION_WORKSPACE_IDLE_OBSERVE=connections`
    makes the browser count client connections instead of CDP traffic.
    `SESSION_WORKSPACE_IDLE_SAMPLE_SECONDS` (default `30`) is the sample
    interval. `SESSION_WORKSPACE_IDLE_SECONDS_PER_MINUTE` (default `60`) is
    the length of one configured minute, for tests. The watcher sets
    `SESSION_WORKSPACE_STOP_REASON` for the stop it records; do not set it.
- `harness` (schema v2–v6) — opt-in strict-v1 role policy: `enabled`,
  `mode` (`audit`|`enforce`), `profile`, the three semantic `roles`, and
  `gates`, plus optional schema-v3–v6 `guards`.
  - Absent or `enabled: false` is a true no-op for panes whose launcher mode
    is empty.
  - A pane launched under audit/enforce keeps that mode. It blocks as drift
    until restarted.
- `orchestration` (schemas 4–6) — optional closed `reviewed-git-v1`
  targets. Each target identifies a child checkout, remote, branches, and merge strategy.
  It uses a configured worker pair or, with `peers`, the caller's workers on that checkout. It
  accepts no commands, scripts, prompts, regexes, or custom gate bypasses.

`workspace.schema.json` in `scripts/` documents this shape. `validate-config.sh`
enforces it in two ways:

- Structurally, via `validate-structural.jq`: unknown/missing keys, name
  uniqueness, env var naming, permission_mode allowlist, etc.
- Against the filesystem: cwd/symlink escape checks, and the secrets file's
  location/mode/ownership/git-ignore state.

### Secret delivery

`secrets.allow` accepts strings and closed objects with required
`key` and `roles` fields, for example
`["SHARED_TOKEN", {"key":"MCP_TOKEN","roles":["master"]}]`.

Visibility rules:

- A string inherits `secrets.visible_to_roles`.
- An object receives the intersection of `secrets.visible_to_roles` and its own `roles`.
- The global list is always a ceiling.
- Omitted/empty global visibility, or empty per-key roles, grants nothing.
- Role names reference the configured `roles` map, not fixed semantic role labels.

Validation fails on any of these:

- unknown roles
- duplicate object role names
- duplicate keys (exact, case-sensitive across both forms)
- invalid identifiers
- unknown object fields
- missing/null object fields

Keys match `^[A-Za-z_][A-Za-z0-9_]*$`.

Both secret-file delivery and the explicit single-key lookup authorize before
resolving values. `on_missing` applies only to entitled keys. A missing
master-only token cannot warn or block executor delivery. A lookup denial names
the allowlist, global ceiling, or per-key roles rule. It does not reveal
whether a value exists.

Reporting:

- Plan reports `secret_keys_by_role` and each pane's `secret_keys` as names only.
- Doctor reports effective names by role and keys with no recipient.
- For object/mixed configs, doctor file checks cover only effective keys and
  name affected roles.
- Legacy string-only doctor file checks still scan every key.
- Doctor is workspace-wide and diagnoses the file. Caller environment overrides
  still apply at delivery.

The authorized `secret-value` command intentionally returns the resolved value.
Never use it to populate reports or logs.

Migration:

- Existing unique-key string configs need no change.
- Before you add a role to global visibility, convert keys that role must not
  receive to object entries in the same edit.
- Update both providers, inspect plan/doctor, then restart affected panes and
  MCP processes.
- No `schema_version` or store migration is required.
- Before downgrading, restore a safely restricted string-only config.
- Never flatten object entries into strings under a widened global list.

This controls workspace delivery. It does not control same-user filesystem
access or independently inherited credentials.

A secret is delivered to exactly one pane's spawned PROCESS environment through
a private, single-use, mode-0600 file. The delivery steps are:

1. `adapters.sh secret-file` resolves and gates the secret (`secrets.allow` /
   `visible_to_roles` / `on_missing`).
2. It writes `KEY=VALUE` lines to that file.
3. It returns only the file PATH, never the value.
4. The pane's launch script reads that path with shell `read`/`export`
   BUILTINS. It never uses `.`/`source`/`eval`, so a value can never be
   re-parsed as code.
5. The launch script exports each var into that pane's own process
   environment, then unlinks the file immediately.

Secrets never go through `tmux set-environment` (hidden or plain), `send-keys`,
or argv. A hidden tmux variable is never passed into a new process's
environment. A plain one is session-scoped, so every later pane would inherit
it. Any pane can also read it with `show-environment`.

Non-secret env that a role's `env_group` marks `pin_to_session: true` DOES use
plain `tmux set-environment` on purpose. That path is for coordination vars a
hand-made pane should also inherit. Secrets are excluded from it by
construction.

## The opt-in harness (schemas 2–6)

With `harness.enabled: true`, the engine's `PreToolUse` hook enforces an
**immutable strict-v1 floor**. The floor is keyed on the per-pane identity the
engine exports at launch (`SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`,
`_PANE_NAME`, `_ROLE`, `_PANE_CWD`, `_HARNESS_MODE`). Relay these consequences
when a user hits them.

### No-op conditions

- A session not launched by `workspace-start`, a schema-v1 project, or
  `enabled: false` is a true no-op — nothing is gated — as long as the pane
  was not launched under an earlier `audit`/`enforce` mode (stale mode is
  drift and blocks until the configured session containing the pane is
  restarted via `$session-workspace:workspace-restart <session-id>`).
### Draft files (0.7.1)

Reviewers, executors, and confined coordinators with
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
Use `--reply-to` for a reply. The dispatch helper attempts to remove an eligible, unchanged own draft after delivery, durable queueing or unsubmitted input (exit 4). `SESSION_CHAT_KEEP_DRAFTS=1` keeps it. A hard failure or an identity or content mismatch also retains the draft. Leave retained drafts in place.
No grant means no staging exception. Existing reviewer top-level drafts must
be restaged here; never move or edit transport files. No config/schema migration
is required. Update both plugins and restart affected agents. Downgrading
restores the executor staging failure and the reviewer transport-edit flaw.

### Reviewer

For reviewers, other native edits remain blocked. Shell remains default-deny
except exact read forms (0.12.11) inside its checkout or explicit per-pane
`read_paths`, and trusted coordination helpers. Use `$session-chat:reply` for
verdicts. Each word is plain (letters, digits, `_ . / : , + = @ % -`) or one
single-quoted run with nothing attached (a printed message path may join runs
with `'\''`). Segments join only with `|`, `||`,
`&&` or `;`. The program is a bare listed name, options are whole listed words
before the operands, and a value option takes the next word. No redirection,
substitution, double quotes, backslashes, unlisted commands or ungranted
sibling reads. `sed` runs only as `sed -n 'N[,M]p' FILE`. Quote `^`, `~`, globs
and spaces: `git diff 'HEAD~1' -- src/x.ts`. A bracket pathspec needs
`git --literal-pathspecs`, `git blame` runs as `git blame [REV] -- PATH`, and
`git config` reads of a file use `--file PATH`. The two allowed repository queries are `git config --get core.hooksPath` and `git config --get-all remote.origin.fetch`.
There is no `git -C`, `grep -f`/`rg -f` or `jq`. Run Git from the checkout, search with `-e PATTERN` and read JSON with
`cat` or `grep`. A pane whose role, engine pane name or
tmux `@name` says reviewer is refused every tool call when no readable
workspace config backs it (`identity.reviewer`).
Reviewers and executors declared in schemas 2–6 may set `sessions[].panes[].read_paths` to up to 16
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

### Message reads

Executors and reviewers may read a complete
delivered message addressed to or sent by their validated pane, or an existing
own draft, using one non-Git read command on its own (never in a pipeline or
list). Use the
quoted `cat '<absolute-path>'` command printed before the incoming body;
inline truncation is not a task-size limit. Delivered files must sit directly
in the plan's messages grant, be private owned regular single-link files,
and have no symlink component or `..` traversal. Parse the generated
`<epoch>-<pid>-<id>-<sender>-to-<recipient>.md` name against all validated
pane names; exactly one endpoint pair must match, with this pane at one end.
Ambiguous or removed peers fail closed. No environment override grants reads.
Reviewers have no broad message-store or ungranted provider-inbox access.
Peer files, queue/archive/ledger state and message-store workdirs are denied.
Recursive reads from ancestors of the store (`rg`, `find`, `du`, recursive
`grep`, `ls -R`) are denied; name explicit safe subdirectories, not glob
exclusions. Own-draft native writes and coordinator behavior are unchanged.
Claude native Read remains ungated; these operand checks do not isolate
arbitrary program internals or concurrent same-user filesystem changes.

### Executor

For executors, explicit per-pane `read_paths` also permit single literal shell
reads using the reviewer read-command restrictions above. Executor tool workdirs
must remain inside its checkout; use relative or absolute operands for shared
docs. Grants never permit writes or composed shell commands outside the checkout.
Executors can also read files in the selected `girishattri-plugins`
version using the same restricted single-command grammar, without `read_paths`.
This includes skills, commands, references, and scripts as data. Use separate
`cat <absolute-path>` calls or `rg --no-config`; it grants no cache writes,
cache workdirs, execution, unselected-version reads, or extra store access.
This cache-read exception does not change confined orchestrator shell reads.
Reviewers and executors can also read provider-installed skill
documentation with the same single literal, non-`git` read grammar.
This includes Codex system skills (`<codex-home>/skills/.system/<skill>/`, only while the
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

### Orchestrator

An orchestrator reads child checkouts and routes writes to their executors.
An ordinary `cp` or shell redirection may read from a child and write outside
every child checkout. A loop may run read commands on child files. Inside a
child, `cd` and `pushd` permit reads. Writes, installs, commits, pushes, and
every form of child `git config` or `git fetch` are refused. An optional
`deny_child_chdir` guard also refuses the directory change itself.
These checks follow literal command operands and child paths bound by a
`for` loop, including in a visible shell program supplied on standard input.
Other variable assignments and filenames produced by pipelines have limited coverage.
The orchestrator routes messages to its configured panes. Strict-v1 refuses broadcasts.

Use scheduler helpers to update the task ledger. Strict-v1 checks direct writes,
ledger paths in `xargs` or `parallel` input, inline interpreter arguments, and
interpreter input from a here-document. The hook inspects visible command text.
A program loaded from a separate file or a path computed inside a program is
outside this check.

- Root and confined orchestrators also deny direct remote-mutating
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

  | Decision rule | Meaning |
  |---|---|
  | `orchestrator.gh_read` | The command matches the reviewed read grammar. |
  | `orchestrator.gh_mutation` | The command mutates remote state. Route it to the executor. |
  | `orchestrator.gh_unsupported` | The command is outside the supported grammar. It is denied. |

  Existing containment and integrity rules also apply to these GitHub CLI calls.
  Update both providers and reload the affected agents.
  Downgrading restores the remote-mutation gap and earlier read restrictions.
  This is an argv guardrail for root and confined orchestrators, not subprocess
  isolation: scripts and stdin-fed interpreters (and root inline code) can still
  invoke gh. Withhold write-scoped orchestrator credentials where remote mutations
  must be impossible. Unclassified MCP calls retain their existing limits.
### Rules for every role

- Strict-v1 refuses `rm`, `mv`, `rmdir`, and `find -delete` when they can
  remove or move the project root, any ancestor, or the home directory.
  A destructive `find` starting at a protected directory can be refused even
  when its name predicates narrow the matches.
  The check resolves directory changes, supported launch wrappers and literal
  paths supplied to these commands. Other utilities and paths constructed by
  a running program are outside this rule.
- Shared shell path checks include attached short-option values
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
  A helper named inside shell code, `eval`, a variable, a here-document, a
  literal pipe into a shell, or a sourced process substitution triggers
  `helper.launch` or `helper.segment`. `env -S` triggers `shell.wrapper`.
- Verdict attribution trusts the tmux server and its pane metadata. A process
  with control of that server can rename or drive a pane. Non-peer workspaces
  permit raw tmux administration. The ancestry check identifies the process
  that actually invoked the helper in the pane.

### Codex permission boundaries

For launch-pinned GitHub credentials and the limits of read grants, read
[gh credentials and read grants](references/gh-credentials-and-read-grants.md).
These are owner requirements and existing policy boundaries, not new grants.

Native Codex approval and sandbox rules apply in addition to the harness.
An admitted helper or read command can still be unavailable under those rules.
Do not translate a Claude permission pattern into a Codex outside-sandbox allow
rule. Do not grant a shell, interpreter, plugin directory, or package manager
blanket execution merely to avoid a prompt.

Codex `allow` rules authorize commands outside the sandbox without prompting;
see the [official rules documentation](https://learn.chatgpt.com/docs/agent-configuration/rules).

Use the selected helper's literal path and supported arguments. For GitHub
reads, use only the current role's documented grammar; the orchestrator `gh`
read grammar does not grant reviewer `gh` access. A branch name or protection
setting does not authorize push or deployment. Route those operations through
the project's existing owner-approved workflow.

For a proposed verifier that needs separate execution authority, read
[owner-reviewed verifier guidance](references/verifier-capability.md). The
guidance adds no permission rule or executable capability.

### Audit and enforce modes

| Mode | Policy denial | Identity/config/drift integrity failure |
|---|---|---|
| `audit` | Reports `AUDIT by session-workspace strict-v1 [...]`. Never blocks. | Blocks |
| `enforce` | Blocks policy denials. The three worker rules below are advisory. | Blocks |

Worker advisories warn in both modes when their provider hook receives the call. Claude registers `EnterWorktree` (`worker.enter_worktree`). Codex registers `spawn_agent` (`worker.spawn_agent`) and MCP calls (`worker.mcp`).

- In `audit` mode, Claude reports the policy denial as one stderr line.
- Codex discards stderr for successful hooks. There, `audit` reports one inert
  top-level `systemMessage` JSON object.
- On Codex the runtime does not expose a per-call shell workdir. Do not present
  Codex `enforce` as complete path containment. `audit` is the recommended
  Codex mode for now.
- Remedy for an integrity failure: run `$session-workspace:workspace-restart <session-id>`
  for the configured session containing that pane.
- Check `behavior.stop_scope` first. If it is `all`, a targeted restart stops all project-marked sessions and starts only the named session. A full start leaves on-demand workers down.
- Never hand-edit the identity variables.

### Guards and diagnostics

- In schemas 3–6, optional `harness.guards` centralize orchestrator protected
  files, child-directory hops, generic lifecycle reminders, and bounded Stop
  health warnings.
- Guard changes require a workspace restart, because their canonical JSON is
  launcher identity.
- `warn_missing_panes` ignores `optional:true`, shell/service panes and
  on-demand workers.
- Stop-health diagnostics run for the configured orchestrator. In schema v5 the root coordinator qualifies, as do environment coordinators whose pane cwd is the project root.
- `branch_ahead` is a neutral local-branch fact, not deploy authorization.
- After a Codex plugin upgrade that changes hook entries, accept/re-trust the
  new session-workspace hook hashes before relying on lifecycle/Stop output.
- Run `$session-workspace:harness-doctor` first when something is unexpectedly blocked.

### Denial diagnostics (`DIAG` line)

- On every `BLOCKED` denial (enforce policy denial or integrity failure), the hook
  writes one more stderr line after it: `DIAG ` followed by one-line JSON.
- The JSON uses schema `diag/1`. It has `emitter` `workspace-hook`, `subject`
  `admission`, `reason` `hook.<rule-id>`, `outcome` `refused`, and
  `state_committed` `false`. Unavailable fields are `null`.
- `helper` names a helper script only when the hook parsed a known installed helper.
  `policy.internal` never names a helper. `version` is this plugin's version.
- `--decision-json` (test mode) always adds a `diagnostic` key: the same object for a
  deny, `null` for every other decision.
- Read `diagnostics/registry.json` in this plugin for every `reason` code and its meaning.
- `audit` reports, allowed calls, and inactive sessions emit no `DIAG` line.
- The `DIAG` line never changes the exit code or the `BLOCKED` text.
- A missing `python3` also gives `hook.runtime.python`.
- The line holds no command, path, argument, or error text.
- Treat a `DIAG` line as an unauthenticated observation. The `BLOCKED` text can echo
  operand text that spans lines, so a line that starts with `DIAG ` can come from the
  operand. No position (first, last, or only) proves who wrote it.
- Do not use a `DIAG` line alone to decide that a call was or was not refused. The exit
  code and the `BLOCKED` line decide that. A missing `DIAG` line does not show success.
- Keep every `DIAG` line you see. Do not reduce several lines to one.

### Quoted literal paths and inert note text

- A quoted or backslash-escaped path that contains `*`, `?`, `{`, `}`, or `[`
  is read as a literal path. Example: `cat 'src/app/(x)/[id]/page.tsx'`.
  Containment and symlink checks are the same as for any other path.
- An unquoted `*`, `?`, `{`, or `[` is still refused (`path.dynamic`). So is a
  glob-bearing path with a `..` part. So is a `$` or backtick inside a token the
  policy reads as a path. The shell-level check refuses real expansions first.
- One exception for executors: a bare `{}` word, as in
  `find src -type f -exec shasum -a 256 {} +`, is decided like `'{}'`. It must
  be a whole word after the program name of an ordinary command. `{}.bak`,
  `x{}`, `src/{}`, `>{}`, and a `{}` that starts a command or follows `then`,
  `else`, `do`, `time`, an assignment or a redirection stay refused. Quote it
  (`'{}'`) when in doubt.
- Shell quoting does not stop Git from globbing a pathspec. For Git, a path with
  those characters is allowed only when ALL of these are true:
  - The subcommand is one of `add`, `rm`, `diff`, `ls-files`, `status`, `restore`,
    `checkout`, `log`, `show`, `commit`. An alias or any other subcommand gets no
    grant.
  - `--literal-pathspecs` is a global option before the subcommand.
  - The only other global option is `-C .` (every `-C` value is exactly `.`, in any
    order with `--literal-pathspecs`). Any other `-C` value, `-c`, `--git-dir`,
    `--work-tree`, `--namespace`, `--no-pager`, or any other global option ends the
    grant.
  - No `--glob-pathspecs`, `--icase-pathspecs`, or `--noglob-pathspecs`.
  Example: `git --literal-pathspecs add -- 'src/[id]/p.tsx'`.
- Without the grant, a Git command is refused with `path.dynamic` when a pathspec
  position contains one of those characters, even for a bare name such as
  `'a[1]'`. A `-C` value with those characters is refused in every case.
  - Pathspec positions are every operand after `--` and the non-option operands
    before it. For an unsupported subcommand only the operands after `--` count.
  - These are not pathspecs: option names, commit messages (`-m 'fix [id]'`),
    `--format=[%h]`, values of the value-taking options the policy lists for
    that subcommand (for example `--grep`, `--author`, `-n`), and, for `diff`,
    `restore`, `checkout`, `log`, `show`, the operands before an explicit `--` and
    revision text such as `HEAD@{1}` or `HEAD^{tree}`.
  - A value that comes as a separate argument after an option the policy does not
    list (for example `--format '[%h]'`) counts as a pathspec. Write `--format=...`.
- Inside the grant, an operand that starts with `:` (pathspec magic) is refused
  with or without glob characters. With a glob-bearing argument present,
  `--pathspec-from-file` and `--pathspec-file-nul` are refused.
- Helper operands (chat, scheduler, and the other reviewed helpers) never get this
  change.
- A task note or reason (`task-done.sh`, `task-block.sh`, `task-review.sh`) and a
  `send-message.sh` message body may contain the text `/plugins/cache/`. Flags,
  their values, task ids, targets, prompt-file operands, and `--note-file`
  operands may not. A line break in any argument is still refused.

## Reviewed orchestration (schemas 4–6)

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

- The engine never renames or respawns an unmanaged pane occupying a planned
  slot. The slot fails with guidance until you use `--adopt --confirmed`
  deliberately. The adoption-candidate details are always shown first, even in
  `reconcile`'s dry-run without `--apply`.
- The engine refuses a same-name unmanaged session by default. Explicit confirmed adoption may claim it. The engine targets the exact tmux session name with `=NAME`.
- `stop`/`restart` never run without confirmation. `stop` refuses outright
  without `--confirmed`. `restart` implies it.
- `workspace-plan`, `workspace-status`, and `workspace-doctor` are
  mutation-free. Run them freely to check state.
- Lifecycle commands and their children use one tmux socket path. Inside
  tmux, they use the socket in `TMUX`. Outside tmux, the default is
  `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/default`. Set
  `SESSION_WORKSPACE_TMUX_SOCKET` to select an absolute socket path. Inside
  tmux, that path must match `TMUX`. A missing `TMUX_TMPDIR` directory stops
  the operation. Only `workspace start` can create a server. It can do so
  at most once and only if tmux reports no server at the selected socket when
  the command begins. If the connection is lost during `stop`, it can report a session as
  absent.

## Schema v5: independent environments

Read [references/environments.md](references/environments.md) for these topics:

- named development/services groups
- optional local orchestrators
- scoped routing/tasks
- multiple browser bindings

Versions 1–4 retain their single-orchestrator contract. V5 pins scope identity
at launch. Never export it manually.

## Peer orchestrators in schema 6

Add `peers.session` to name the declared root orchestrator session. From a user
terminal, start another instance with `workspace start SESSION-N` (N from 2
through 999). Each orchestrator starts workers with `workspace start --checkout
ID --role executor|reviewer`. Add `--label L` to distinguish workers or
`--show` to start the worker beside its owner.

Use `workspace status --json` to find a worker's name, checkout, and owner.
`workspace show NAME` joins the worker to its owner's window. `workspace hide NAME`
moves it to a separate window in that session. `SESSION_WORKSPACE_HIDDEN_SIZE`
defaults to `160x48` and accepts `COLSxROWS` of at least `40x10`.
The engine pins `XDG_STATE_HOME` for every launched pane so they share the
registry. Stop an idle worker with `workspace stop --worker NAME --confirmed`.
A held name or checkout reports its owner and exits 3. A reached limit exits 1.
See the [peer configuration, ownership rules and migration procedure](references/environments.md#peer-orchestrators-schema-6).

Session-workspace 0.12.0 removed the optional Jev diagnostic helper. A v5 config
that still has `integrations`, `environments[].jev`, or `"integrations"` in
`stores.pin` fails validation. Delete those fields to migrate.
