---
name: task-review
description: "Move an assigned task to review and auto-dispatch its audit packet to the configured reviewer."
---

# Task Review

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment (the note is
required — typically a commit SHA or a one-line summary of what to audit), with
no `export` beforehand, no `env` or variable-assignment prefix, and no other
command chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-review.sh" "<task-id>" [--force] "<note>"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
value differs from the ledger home stated in your assignment — stop and request
a pane relaunch with the correct environment instead of deriving another ledger.

## Transport contract

`task-review` can update the ledger and then perform nested session-chat/tmux
transport to the reviewer and assigner. In Codex, request scoped
escalation/approval for the exact installed helper on the first attempt whenever
it may dispatch or notify. Invoke that helper as one literal Bash segment with
raw token zero still `bash`; never work around the sandbox with `bash -c`, a
wrapper, `env`, an assignment prefix, an export, a pipeline, chaining,
redirection, substitution, or broad provider-home access.

Escalation grants transport access only. The recorded role and recipient, exact
arguments, confirmation requirements, and lifecycle rules remain authoritative;
never use --force to repair transport. A dispatch-only retry is legal only while
the task is already in `review`, has no successful reviewer-dispatch timestamp,
and the prior dispatch is known to have failed. If dispatch succeeded but
recording its timestamp failed, delivery is ambiguous even though the helper
cannot distinguish that state on a later call: do not retry until recipient or
outbox evidence proves no packet was delivered; never duplicate a delivered
review packet.

The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`. If the task has a `reviewer`, the script builds a private review packet containing the shared ledger homes and original assignment, then dispatches it automatically. Review state is retained if delivery fails so it can be retried. The reviewer approves with `$session-scheduler:task-done` or rejects with `$session-scheduler:task-block`.
