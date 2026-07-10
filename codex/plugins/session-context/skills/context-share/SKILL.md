---
name: context-share
description: "Share a saved session context snapshot with another named tmux pane."
---

# Context Share

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's absolute source path by going up two directories from `<plugin-root>/skills/context-share/SKILL.md`. Never derive it from the project working directory or embed a cache version.

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or pwd when not in a git repo) unless already set.

Parse the first argument as the target session and the optional second argument as the snapshot name. If the target is missing, tell the user:

```text
Usage: $session-context:context-share <session-name> [snapshot-name]
```

If no snapshot name is provided, derive one from the current directory. Run:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
```

If tmux is not active, explain that sharing requires running Codex inside tmux.
If the snapshot does not exist, suggest `$session-context:context-generate <snapshot-name>`. If the target session is not found, suggest `$session-chat:panes`.

Sharing sends only a notification; it does not copy the snapshot. State that the recipient can load it only when both panes resolve the same absolute `SESSION_CONTEXT_HOME` (normally the same repo, or an intentionally shared workspace context directory). The script prefers session-chat's hardened delivery path when installed and uses the local tmux fallback only when necessary.
