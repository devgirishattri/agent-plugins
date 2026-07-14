---
name: task-block
description: "Mark a scheduler task blocked (or reject a review) and notify the assigner when possible."
---

# Task Block

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment, with no `export`
beforehand, no `env` or variable-assignment prefix, and no other command
chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-block.sh" "<task-id>" [--force] "<reason>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

## Transport contract

`task-block` writes the legal `blocked` transition before its nested
session-chat/tmux notification to the assigner. In Codex, request scoped
escalation/approval for the exact installed helper on the first attempt whenever
it may notify. Invoke that helper as one literal Bash segment with raw token zero
still `bash`; never work around the sandbox with `bash -c`, a wrapper, `env`, an
assignment prefix, an export, a pipeline, chaining, redirection, substitution,
or broad provider-home access. Escalation grants transport access only; the
recorded role and recipient, exact arguments, confirmation requirements, and
lifecycle rules remain authoritative.

If the helper warns that notification failed, the task is already `blocked`:
this is partial success. Report that state and never rerun the helper.
Never use --force to repair a notification. Only when authorized, send a
separate exact session-chat message to the recorded recipient.

Legal from `created`, `assigned`, or `review` (review rejection); other transitions are rejected unless `--force`. Unblock by re-running task-assign (blocked → assigned is legal). Report that the task was marked blocked.
