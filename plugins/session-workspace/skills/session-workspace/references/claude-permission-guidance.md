# Claude permission guidance for coordination commands (H9)

Status: guidance, conditional until tested in your own project. This page
ships no permission rule and changes no setting.

If a native Claude Code approval pause stops a command that strict-v1 already
admits, such as a read-only `gh run list` or a scheduler helper call, a project
owner can consider a narrow allow rule in the project's `.claude/settings.json`.

## Preconditions

- strict-v1 runs in enforce mode and its hooks are verified active in the
  pane. Audit mode only logs policy denials; it does not block them.
- An allow rule does not unconditionally remove a prompt. Deny and ask rules
  take precedence over allow, and hooks run before the permission decision.
  See the Claude Code permissions documentation:
  <https://code.claude.com/docs/en/permissions>.

## Reasonable candidates

Allow rules for exact, read-only or plugin-reviewed forms only, for example:

- read-only GitHub status: `gh run list`, `gh run view`, `gh pr view`,
  `gh pr checks`, each with an explicit `--repo`
- the installed session-chat and session-scheduler helper scripts, by their
  exact installed path, as one literal `bash <path>` command

These are descriptions, not ready-to-paste rules. Write the narrowest rule
form your Claude Code version supports.

## Do not allow

- `git push` in any form, including to unprotected branches. A push can
  publish code, trigger a deployment, or target another remote, whatever the
  branch protection says.
- deploys, database migrations, `rm`, force operations, settings edits, or any
  command that writes outside the project
- broad wildcard rules such as `Bash(bash:*)`, `Bash(gh:*)` or a whole plugin
  cache directory

Production actions stay with explicit human authorization in the pane that
performs them.

## Test before adopting a rule

- Positive: the exact intended command runs without the pause.
- Negative controls, each still paused or refused: a different helper, path
  or arguments; force and mutating variants; composition with other commands.
- A command that strict-v1 denies stays blocked with the rule in place.

## Codex is different

Do not translate these rules into Codex `.rules` allow entries. A Codex allow
rule permits execution outside the sandbox, which is a different and larger
grant; see the Codex rules documentation:
<https://learn.chatgpt.com/docs/agent-configuration/rules>. An allow rule is never human consent for anything it does not name
exactly.
