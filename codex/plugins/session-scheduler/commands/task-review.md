---
description: Move an assigned scheduler task to review
argument-hint: <task-id> [--force] <note>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment (the note is
   required — typically a commit SHA or a one-line summary of what to audit),
   with no `export` beforehand, no `env` or variable-assignment prefix, and no
   other command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-review.sh" "<task-id>" [--force] "<note>"
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set — or the inherited
   value differs from the ledger home stated in your assignment — stop and
   request that this pane be relaunched with the correct environment instead of
   deriving another ledger.

   **Transport contract:** `task-review` can update the ledger and then perform
   nested session-chat/tmux transport to the reviewer and assigner. In Codex,
   request scoped escalation/approval for the exact installed helper on the first attempt
   whenever it may dispatch or notify. Invoke it as one literal Bash segment
   with raw token zero still `bash`; never use `bash -c`, a wrapper, `env`, an
   assignment prefix, an export, a pipeline, chaining, redirection,
   substitution, or broad provider-home access to bypass the sandbox.
   Escalation grants transport access only: the recorded role and recipient,
   exact arguments, confirmation requirements, and lifecycle rules remain
   authoritative. Never use --force to repair transport.

3. The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`; `--force` overrides and records "forced" in history.
4. If the task has a configured reviewer, the script automatically dispatches a private audit packet with the shared ledger homes and original assignment. A dispatch-only retry is legal only while the task is already in `review`, has no successful reviewer-dispatch timestamp, and the prior dispatch is known to have failed. If dispatch succeeded but recording its timestamp failed, delivery is ambiguous even though the helper cannot distinguish that state on a later call: do not retry until recipient or outbox evidence proves no packet was delivered; never duplicate a delivered review packet. On hard dispatch failure, the task stays in `review` and the script warns; there is no one-line send downgrade.
5. The reviewer approves with `$session-scheduler:task-done <task-id> <note>` or rejects with `$session-scheduler:task-block <task-id> <reason>`. Review state remains recorded if dispatch needs retrying.
