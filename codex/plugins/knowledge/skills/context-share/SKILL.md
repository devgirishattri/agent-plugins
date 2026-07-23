---
name: context-share
description: "Share a saved session context snapshot with another named tmux pane."
---

# Context Share

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_CONTEXT_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Invoke the context helper as one literal Bash
segment, with no `export` beforehand, no `env` or variable-assignment prefix,
and no other command chained, piped, redirected, or substituted around it.

If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another context
store.

Parse the first argument as the target session and the optional second argument as the snapshot name. If the target is missing, tell the user:

```text
Usage: $knowledge:context-share <session-name> [snapshot-name]
```

If no snapshot name is provided, derive one from the current directory. Run:

```bash
bash "<PLUGIN_ROOT>/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
```

## Transport contract

`context-share` performs nested session-chat/tmux transport. In Codex, request
scoped escalation/approval for the exact installed helper on the first attempt
whenever it may send. Keep it one literal Bash segment with raw token zero still
`bash`; never work around the sandbox with `bash -c`, a wrapper, `env`, an
assignment prefix, an export, a pipeline, chaining, redirection, substitution,
or broad provider-home access. Escalation grants transport access only; the
chosen recipient and arguments remain authoritative. A failed share is
transport-only with respect to snapshot contents: no snapshot lifecycle
transition occurs, although resolving the configured store may create its
directory or harden owner-only permissions. Fixing the transport and re-running
the same legal share command is safe.

If tmux is not active, explain that sharing requires running Codex inside tmux.
If the snapshot does not exist, suggest `$knowledge:context-generate <snapshot-name>`. If the target session is not found, suggest `$session-chat:panes`.

Sharing sends only a notification; it does not copy the snapshot. State that
the recipient can load it only when both panes inherited the same absolute
`SESSION_CONTEXT_HOME` (normally the same repo, or a workspace launcher that
starts both panes with one shared context directory). A pane with a different
inherited value must be relaunched. The script prefers session-chat's hardened
delivery path when installed and uses the local tmux fallback only when
necessary.
