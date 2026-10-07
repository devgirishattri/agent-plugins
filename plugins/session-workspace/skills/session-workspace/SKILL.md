---
name: session-workspace
description: When and how to use the session-workspace plugin's config-driven tmux lifecycle commands (doctor/plan/start/status/stop/restart/reconcile/install), its opt-in strict-v1 multi-agent harness (harness-status/harness-doctor, the PreToolUse role policy), and schema-v4 reviewed Git orchestration. Use this before invoking any /session-workspace:workspace-* or /session-workspace:harness-* command (including /session-workspace:workspace-orchestrator) so you understand the config model, the real flags, the safety gates, and the provider-neutral coordination boundary.
---

# session-workspace: config-driven tmux workspace engine

`session-workspace` is a shared engine. It reads a versioned, project-local
`.agent-workspace/workspace.json` config and drives tmux session/window/pane
lifecycle from it. The engine covers config load/validation, mutation-free
planning, runtime argv/env construction, and create/adopt/reconcile/stop/restart.

## Commands

| Command | Purpose |
|---|---|
| `/session-workspace:workspace-doctor` | Read-only dependency/config health check |
| `/session-workspace:workspace-plan` | Dry-run plan (human + JSON); mutates nothing |
| `/session-workspace:workspace-start` | Bring up sessions/panes/agents/services (idempotent) |
| `/session-workspace:workspace-status` | Current lifecycle state; mutates nothing |
| `/session-workspace:workspace-stop` | Tear down sessions/panes (destructive, needs `--confirmed`) |
| `/session-workspace:workspace-restart` | Stop then start (destructive, confirmation implicit) |
| `/session-workspace:workspace-reconcile` | Dry-run by default; `--apply` repairs drift; `--adopt --confirmed` claims unmanaged panes |
| `/session-workspace:workspace-install` | Install/refresh the machine-wide `workspace` dispatcher on PATH; no config, no tmux, idempotent |
| `/session-workspace:workspace-browser-config` | Render/apply project MCP entries for the configured browser |
| `/session-workspace:harness-status` | Read-only: is the opt-in harness active (mode/profile/roles/gates), and does this pane's engine identity match the plan |
| `/session-workspace:harness-doctor` | Read-only harness health: config validity, activation, hook registration, python3, live identity match |
| `/session-workspace:workspace-orchestrator` | Schema-v4 status/plan/dispatch/review/commit/push/deploy lifecycle using configured executor/reviewer pairs |
| `/session-workspace:verification-recipe` | Author or maintain a project-local launch/doctor/drive/evidence/cleanup recipe; guidance only, no new runtime, permission, or approval gate |
| `/session-workspace:blast-radius` | Report-only review of a diff's indirect consumers and safety assumptions, with checks only within existing authorization |
| `/session-workspace:adversarial-review` | Optional budgeted independent pass that tries to break an exact subject; evidence-based dispositions; consensus is not approval |
| `/session-workspace:benchmark-check` | Check a performance claim: comparable inputs, correctness/work counts, interleaved repeated samples, limiter, explicit inconclusive |
| `/session-workspace:behavioral-eval` | Design/assess behavioral evals: baseline, positive/negative controls, grading on completed executions and artifacts; model spend only when authorized |
| `/session-workspace:pr-status` | Read-only GitHub PR blocker report (ready/blocked/waiting/inconclusive); orchestrator-only under strict-v1; never merges or comments |

## Configuration model (enforced)

A project opts in by creating `.agent-workspace/workspace.json`. Set
`schema_version: 1`, `2` for the optional harness, `3` for shared guard packs,
or `4` for reviewed orchestration. The config describes:

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
- `harness` (schema v2/v3/v4) — opt-in strict-v1 role policy: `enabled`,
  `mode` (`audit`|`enforce`), `profile`, the three semantic `roles`, and
  `gates`, plus optional schema-v3/v4 `guards`.
  - Absent or `enabled: false` is a true no-op for panes whose launcher mode
    is empty.
  - A pane launched under audit/enforce keeps that mode. It blocks as drift
    until restarted.
- `orchestration` (schema v4 only) — optional closed `reviewed-git-v1`
  targets. A target binds a safe child cwd to its configured executor/reviewer
  pair, named remote, work/release branches, and fixed merge strategy. It
  accepts no commands, scripts, prompts, regexes, or custom gate bypasses.

`workspace.schema.json` in `scripts/` documents this shape. `validate-config.sh`
enforces it in two ways:

- Structurally, via `validate-structural.jq`: unknown/missing keys, name
  uniqueness, env var naming, permission_mode allowlist, etc.
- Against the filesystem: cwd/symlink escape checks, and the secrets file's
  location/mode/ownership/git-ignore state.

### Secret delivery

From 0.8.0, `secrets.allow` accepts strings and closed objects with required
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

## The opt-in harness (schema v2/v3/v4)

With `harness.enabled: true`, the engine's `PreToolUse` hook enforces an
**immutable strict-v1 floor**. The floor is keyed on the per-pane identity the
engine exports at launch (`SESSION_WORKSPACE_CONFIG`, `_PROJECT_ROOT`,
`_PANE_NAME`, `_ROLE`, `_PANE_CWD`, `_HARNESS_MODE`). Relay these consequences
when a user hits them.

### No-op conditions

- A session not launched by `workspace-start`, a schema-v1 project, or
  `enabled: false` is a true no-op. Nothing is gated.
- This holds only if the pane was not launched under an earlier `audit`/`enforce` mode.
- A stale mode is drift. It blocks until you restart the configured session
  containing the pane with `/session-workspace:workspace-restart <session-id>`.

### Draft staging (reviewer, executor, environment-scoped coordinator)

From 0.7.1:

- Condition: the validated plan grants this pane's role `messages`. The path
  comes from the plan, never from inherited `SESSION_*` env.
- With that grant, the only store write is the pane's own drafts directory:
  `<messages grant>/drafts/<pane-name>/<name>.md|.txt`.
- Use native create/edit/delete only.
- The parent must canonicalise to exactly that directory.
- The engine refuses these:
  - symlinked directories, and any path (including `../` forms) resolving outside the directory
  - names outside the safe-name rule
  - existing targets that are not single-link regular files
  - moves
  - other panes' drafts
  - the store top level
  - delivered dispatch files
  - `queue/`/`archive/`/ledger state
  - any patch that also touches another path
- No grant means no staging exception (fail closed).
- An executor's ordinary checkout writes are not a substitute staging contract.
- The root orchestrator's authority over store and transport files is unchanged.
- Arbitrary executor shell commands (outside the single literal read grammar)
  must not name a granted messages store, even one nested in their cwd. The
  same holds for confined-coordinator shell commands.
- Reviewer safe reads and an executor's single safe read of a store in its cwd
  are unchanged.
- Portable guidance: read dispatch files with `Read` or a trusted helper.
- Earlier releases let reviewers write any top-level `.md`/`.txt` in the
  store. That also reached other panes' pending dispatch files. This is
  removed, and downgrading restores it.

### Reviewer

- Edit/Write/NotebookEdit/apply_patch are blocked everywhere except draft
  staging above.
- Shell writes remain denied.
- Shell is default-deny. Two exceptions apply:
  - One literal read-only command inside its own checkout or explicit per-pane
    `read_paths`. No pipes, redirection, `sed`, or ungranted sibling reads.
  - Trusted coordination helpers: reply to the orchestrator,
    `task-done`/`task-block`, context and read-only knowledge helpers.
- Send verdicts as a single-line `/session-chat:reply`, a scheduler note, or a
  staged file sent with `dispatch-to-session.sh`.

### Credentials, read grants and permission prompts (guidance)

- [references/gh-credentials-and-read-grants.md](references/gh-credentials-and-read-grants.md):
  give each pane its gh credential at launch instead of a per-command
  `GH_CONFIG_DIR`; `read_paths` grant reading, never execution.
- [references/claude-permission-guidance.md](references/claude-permission-guidance.md):
  narrow Claude allow rules that can reduce classifier pauses for read-only and
  helper commands, and the commands never to allow.

- [references/verifier-capability.md](references/verifier-capability.md):
  requirements for any owner-reviewed verifier execution route (content,
  dependency and argument binding); it installs no runner.

These pages are documentation only; they add no grant or permission rule.

### Read grants (`read_paths`) for reviewers and executors

Schema v2–5 reviewers and executors can set `sessions[].panes[].read_paths` to
up to 16 files/directories.

- Write each path relative to the project root, or as a canonical absolute path
  for external repositories.
- A file grants exact-file access. A directory grants its descendants.
- Validation rejects parent traversal, overlapping grants, configured
  stores/memory/secrets, provider homes, and foreign v5 environments.
- Condition: a path is missing, is not a regular file or directory, or has a
  symlink component. Result: `workspace-plan` shows it as `unavailable`.
  - Launch/restart/adopt of that pane is refused.
  - A running pane is blocked until the path is restored.
  - Other panes and stop/status keep working.
- Recursive symlink-follow options are denied: `rg -L`, `grep -R`/`-S`,
  `find -L`, `du -L`, `ls -L`. Directory `diff` is also denied. Compare
  explicit files instead.
- `rg` must start with literal `--no-config` (`rg --no-config PATTERN PATH`).
  This stops an inherited `RIPGREP_CONFIG_PATH` from adding symlink following
  or a preprocessor.
- `--pre`, `--hostname-bin` and `--search-zip`/`-z` are denied.
- Relative operands resolve against the effective tool `cwd`/`workdir`.
  Run helpers from the configured pane cwd.
- These paths affect shell reads and reviewer tool workdirs only. They do not
  grant helper-store access, native Read/Grep/Glob permissions, `--add-dir`,
  or writes. Provider permissions still apply.
- `SESSION_WORKSPACE_READ_PATHS_JSON` is engine-owned launch identity, never a
  user tunable.
- Changing or removing paths fails closed in both modes until the affected
  session is restarted.
- Omitted/empty paths keep old behavior.
- Limit: hooks are not an atomic filesystem sandbox against racing same-uid swaps.

### Message reads (0.10.0)

Executors and reviewers can read a complete delivered message addressed to or
sent by their validated pane. They can also read an existing own draft. Use the
existing single literal non-Git read grammar.

- Use the quoted `cat '<absolute-path>'` command printed before the incoming
  body. Inline truncation is not a task-size limit.
- A delivered file must sit directly in the plan's messages grant. It must be
  a private owned regular single-link file with no symlink component or `..`
  traversal.
- Parse the generated `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md` name
  against all validated pane names. Exactly one endpoint pair must match, with
  this pane at one end.
- Ambiguous or removed peers fail closed.
- No environment override grants reads.
- Reviewers lose broad message-store and ungranted provider-inbox access.
- Peer files, queue/archive/ledger state and message-store workdirs are denied.
- Recursive reads from ancestors of the store (`rg`, `find`, `du`, recursive
  `grep`, `ls -R`) are denied. Name explicit safe subdirectories, not glob
  exclusions.
- Own-draft native writes and coordinator behavior are unchanged.
- Limit: Claude native Read remains ungated. These operand checks do not
  isolate arbitrary program internals or concurrent same-user filesystem changes.
- Upgrade: update session-chat to 0.17.13 and workspace to 0.10.0, then
  restart panes. No schema/store migration.
- Rollback restores the executor read failure and broader reviewer access.

### Executor

Baseline containment:

- Edits and shell path operands must stay inside the executor's own checkout.
  The fixed `/dev/null` sink/source is the only exempt operand.
- Inline code (`bash -c`, `python -c`) and sandbox-escape flags are blocked.
- The executor can message only the orchestrator.
- Read dispatch files with the literal read command above.
- Stage multiline prompt files only through draft staging above. Checkout,
  scratchpad, and `$TMPDIR` staging are not the contract. Containment refuses
  `$TMPDIR` writes.

Shell reads:

- Explicit per-pane `read_paths` also permit single literal shell reads. They
  use the reviewer read-command restrictions above.
- Reads cover the executor's own checkout plus its grants. Helper stores are
  never readable. Message inboxes are readable only under the message-read
  rules above.
- Executor tool workdirs must remain inside its checkout. Use relative or
  absolute operands for shared docs, for example `cat ../docs/guide.md`.
- Grants never permit writes or composed shell commands outside the checkout.
- A command that fails the read grammar (for example `rg` without
  `--no-config`) falls back to ordinary executor containment. It still runs
  when every operand is inside the checkout.
- Limit (known): that floor checks operands, not recursive traversal or
  inherited tool configuration.

Version additions:

- From 0.7.1, executors can also read files in the selected installed
  `girishattri-plugins` plugin version. Use the same single-command read
  grammar. No `read_paths` is needed.
  - Readable as data: skills, commands, references, and scripts.
  - Use separate `cat <absolute-path>` calls or `rg --no-config`.
  - This grants no cache writes, cache workdirs, execution, unselected-version
    reads, or store access.
  - Confined orchestrator shell behavior is unchanged.
  - No config migration is needed. Update the plugin and restart affected agents.
  - Downgrading restores the earlier executor cache-read restriction.
- From 0.7.3, reviewers and executors can also read provider-installed skill
  documentation. Use the same single literal, non-`git` read grammar.
  - Codex system skills: `<codex-home>/skills/.system/<skill>/`, only while
    the system-skills marker exists.
  - User skills: `<codex-home>/skills/<skill>/`, `<claude-home>/skills/<skill>/`.
    The directory must hold a regular `SKILL.md`.
  - Files must be regular, single-link, inside that skill directory, with no
    symlink or hidden components (except `.system`).
  - Denied: workdirs, helper operands, writes, execution, other provider-home content.
  - Limit (known): skills from non-`girishattri-plugins` marketplace plugins stay denied.
- From 0.7.4, the engine path-checks these for reviewer reads, executor
  containment, and orchestrator child writes:
  - paths attached to short options (`-f/x`, `-o/x`, `-uo/x`)
  - every operand after `--`
  - Redirection targets are checked against the shell cwd.
  - `grep`/`rg`/`sort` use reviewed option tables (`-e/api/` stays a pattern).
  - Other commands are checked conservatively. Pass unusual in-scope values as
    separate arguments.
  - Reviewers never get `sort` output options.
  - No config migration. Restart agents after updating.
  - Downgrading restores the 0.7.3 gap.

### Orchestrator

- It cannot edit or run mutating commands against a child checkout.
- It routes only to its configured executor/reviewer panes.
- `broadcast` is not available under strict-v1.

#### From 0.9.0: `gh` rules

Root and confined orchestrators deny direct remote-mutating `gh` commands
(`orchestrator.gh_mutation`). The denial applies even without a child
filesystem operand. Route mutations to the executor.

| Rule id | What it covers |
|---|---|
| `orchestrator.gh_mutation` | Direct remote-mutating `gh` commands. Always denied. |
| `orchestrator.gh_read` | Reviewed reads: `run list/view`, `pr list/view/diff/checks`, `workflow list/view`, `release list/view` with an explicit `--repo`/`-R OWNER/NAME`; positional `repo view OWNER/NAME`; `api repos/OWNER/NAME/...` or `api repositories/ID/...` with effective GET. |
| `orchestrator.gh_unsupported` | Everything else gh-shaped: aliases, extensions, executable paths, env assignments, wrappers and launchers (`timeout`, `nice`, `find -exec`, ...), composition, expansions, redirections, stdin inputs, browser flags, command-line host overrides, headers, API caching, and unknown flags (grammar reviewed against gh 2.100.0). |

- API `-f`/`-F`/`--input` need an explicit uppercase `--method GET`/`-X GET`.
- File-backed inputs send the file contents to GitHub even on GET. Confined
  coordinators keep filesystem containment for them.
- Use `--json`/`--jq`/`--limit` instead of pipes. Quoted jq `|`/`?` is data.
- A `gh` argument to a non-data command (for example `git log --author gh`) is
  also refused.
- Executor/reviewer rules are unchanged.
- Limit: this is an argv guardrail for both orchestrator kinds, not subprocess
  isolation. A script file or an interpreter fed on stdin can still run `gh`.
- Where remote mutations must be impossible, scope the orchestrator pane's
  GitHub token (per-role secret visibility).

### From 0.11.1: implicit memory capture

Orchestrators and executors can run the knowledge `memory-auto-capture.sh`
helper (implicit inbox-only `remember`). Reviewers are denied.

- The only accepted arguments are exactly
  `[--store PATH] --staged FILE [--staged FILE ...]`.
- `--batch-dir` and every other argument are refused.
- The writer, not the policy, enforces evidence presence, provenance stamping,
  and the pending caps.
- Each `--staged` file must pass normal literal-file containment.
- Knowledge 0.5 implicit capture needs this release under strict-v1.
- If an older harness refuses capture, that is a compatibility limit. It is not
  permission to bypass the refusal. Update and restart agents, then retry.

### Rules for every role

- `sudo`/`doas`/`su`/`runuser`/`pkexec` are refused for every role at any
  wrapper hop.
- Any unsupported wrapper option is also refused (`exec -a`, `nohup --`,
  `time -o`, `env -S` all fail closed).
- The plugin README enumerates the accepted `env`/`command`/`builtin`/`exec`/
  `nohup`/`time` forms.
- Invoke installed helpers as one literal
  `bash <selected-cache-path>/scripts/<name>.sh args...`. Use no env prefix,
  wrapper, chaining, expansion, stale version, or copied script.

### Audit and enforce modes

| Mode | Policy denial | Identity/config/drift integrity failure |
|---|---|---|
| `audit` | Reports `AUDIT by session-workspace strict-v1 [...]`. Never blocks. | Blocks |
| `enforce` | Prints `BLOCKED ...` and blocks. | Blocks |

- In `audit` mode, Claude reports the policy denial as one stderr line.
- Codex discards stderr for successful hooks. There, `audit` reports one inert
  top-level `systemMessage` JSON object.
- On Codex the runtime does not expose a per-call shell workdir. Do not present
  Codex `enforce` as complete path containment. `audit` is the recommended
  Codex mode for now.
- Remedy for an integrity failure: run `/session-workspace:workspace-restart <session-id>`
  for the configured session containing that pane.
- That restart kills and recreates ALL of that session's configured panes, not
  just the drifted one.
- Never hand-edit the identity variables.

### Guards and diagnostics

- In schema v3/v4, optional `harness.guards` centralize orchestrator protected
  files, child-directory hops, generic lifecycle reminders, and bounded Stop
  health warnings.
- Guard changes require a workspace restart, because their canonical JSON is
  launcher identity.
- `warn_missing_panes` ignores `optional:true` and shell/service panes.
- Workspace-health diagnostics emit only from the configured orchestrator.
- `branch_ahead` is a neutral local-branch fact, not deploy authorization.
- After a Codex plugin upgrade that changes hook entries, accept/re-trust the
  new session-workspace hook hashes. Do this before you rely on lifecycle/Stop output.
- When something is unexpectedly blocked, run `/session-workspace:harness-doctor` first.

### Denial diagnostics (`DIAG` line, 0.11.7)

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

### Quoted literal paths and inert note text (0.11.7)

- A quoted or backslash-escaped path that contains `*`, `?`, `{`, `}`, or `[`
  is now read as a literal path. Example: `cat 'src/app/(x)/[id]/page.tsx'`.
  Containment and symlink checks are the same as for any other path.
- An unquoted `*`, `?`, `{`, or `[` is still refused (`path.dynamic`). So is a
  glob-bearing path with a `..` part. So is a `$` or backtick inside a token the
  policy reads as a path. The shell-level check refuses real expansions first.
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
  `send-message.sh` message body may now contain the text `/plugins/cache/`. Flags,
  their values, task ids, targets, prompt-file operands, and `--note-file`
  operands may not. A line break in any argument is still refused.
- No config migration. Update the plugin and restart affected agents. This release
  ships with scheduler 0.7.6. To roll back, install the previous release:
  session-workspace 0.11.5 (and session-scheduler 0.7.5, commit 69041bb).

## Reviewed orchestration (schema v4)

When `orchestration.enabled` is true, use the `workspace-orchestrator` skill
(`/session-workspace:workspace-orchestrator`).

- The normalized workspace plan is the sole target map.
- The orchestrator coordinates. Every Git mutation runs in the target executor.
- The fixed lifecycle requires:
  - correlated explicit plan approval
  - user confirmation
  - scheduler-tracked execution
  - reviewer-authored explicit audit approval
  - separate commit/push/deploy confirmations
- Freshness windows come from `harness.gates`.
- Ledger and session-chat records are machine-verifiable evidence.
- User confirmations remain conversational. Never describe them as harness-enforced.

## Safety gates worth relaying to the user

- The engine never renames or respawns an unmanaged pane occupying a planned
  slot. The slot fails with guidance until you use `--adopt --confirmed`
  deliberately. The adoption-candidate details are always shown first, even in
  `reconcile`'s dry-run without `--apply`.
- The engine never touches a tmux session with the same configured name that it
  did not create. It uses exact `=NAME` targeting only, never a prefix match.
- `stop`/`restart` never run without confirmation. `stop` refuses outright
  without `--confirmed`. `restart` implies it.
- `workspace-plan`, `workspace-status`, and `workspace-doctor` are
  mutation-free. Run them freely to check state.

## Schema v5: independent environments and optional diagnostics

Read [references/environments.md](references/environments.md) for these topics:

- named development/services groups
- optional local orchestrators
- scoped routing/tasks
- multiple browser bindings
- the fully optional removable Jev diagnostic helper

Versions 1–4 retain their single-orchestrator contract. V5 pins scope identity
at launch. Never export it manually. Jev stays off unless configured. Jev
supplies no approvals.

New inherited operational tunables:

- `SESSION_WORKSPACE_JEV_MAX_REQUESTS`: default 0, cumulative 0–10000 request ceiling.
- `SESSION_WORKSPACE_JEV_TIMEOUT_MS`: default 5000, range 1–15000.

The optional pinned `integrations` store is launch-inherited as
`SESSION_WORKSPACE_INTEGRATIONS_HOME`. The reference holds the full data,
credential, fallback and removal contracts. Do not upload logs merely because
Jev is enabled.
