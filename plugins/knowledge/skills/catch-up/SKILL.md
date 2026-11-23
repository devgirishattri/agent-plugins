---
name: catch-up
description: "Brief the user on where the current session stands, read-only: what changed, what is verified, what is open, and what needs the user. Use for \"what changed\", \"where are we\", \"where do we stand\", \"catch me up\", \"what do you need from me\". Saves and sends nothing."
when_to_use: "The user asks what changed, where the session stands, or what you need from them (\"what changed\", \"where are we\", \"where do we stand\", \"catch me up\", \"what do you need from me\"). Do not use it to save or hand off session state (\"save my context\", \"generate a handoff\", \"capture where we are\"): use context-generate. Do not use it to wrap up: use distill. Do not use it for lessons: use reflect. For a fresh scheduler status query, use task-status or task-board: catch-up never queries the ledger."
argument-hint: "[task-id]"
---

# Catch up

Give the user a short brief of the current session. Separate what you verified from what others reported.

This skill is read-only. It saves no snapshot and writes no memory, docs, or task. It sends no message.

## Routing

| Request | Owner |
|---|---|
| Save or hand off session state | `context-generate` |
| Wrap up the session | `distill` |
| Lessons from the task | `reflect` |
| A fresh scheduler status query, also for one named task | the scheduler's `task-status` or `task-board` |

## Window

Cover the current session, from the user's previous substantive request up to now.

- A substantive request asks for work or a decision.
- Acknowledgements ("ok", "thanks", "continue") do not count. The catch-up request itself does not count.
- Tool notifications, hook output, and messages from other panes or agents do not move the start of the window.
- If the user names a different window, use it when this session's evidence covers it. Say when it does not.
- Never mine other sessions or stores.
- If earlier context was summarized or compacted, say that the brief relies on that summary.

## Optional re-check

You may run cheap read-only checks of current state, such as `git status` and `git log`. Label each result as checked now. Do not rerun tests. Change nothing for the brief.

## Named task

When the user names a scheduler task, report it from this conversation only.

- Use the most recent `task-status` output or quoted report for that task that is already in the current conversation.
- Name the source and its time, for example "task-status output at 14:02" or "report from the executor pane".
- Label the state stale when later work in this session could have changed it.
- Label the state unknown when the conversation holds no status for that task.
- Do not run `task-status` or any other scheduler command for the brief. Do not read the ledger or any other store.

A direct request for a fresh scheduler status is a different request, even for one named task. It uses the scheduler's own `task-status` workflow, not this skill.

## Brief

Start with one sentence that states the current state. Keep the brief short. Keep stable ids and paths. Omit an empty section, except Decisions. Use these sections in this order:

1. **Changed.** Files, commits, messages sent, and task transitions. For each, say how you know.
2. **Verified.** Outcomes that you checked in this session. Name the check for each.
3. **Reported, not verified.** Claims from other panes, subagents, or tools, and your own unchecked work. Never promote a report to verified.
4. **Open work.** Work in progress, blocked, or not started. Include background work that still runs.
5. **Decisions for you.** List only real pending human decisions:
   - an approval that a workflow requires
   - a choice that you cannot settle from the request or the code
   - a risky or irreversible action that awaits confirmation

   For each decision, give the options and the known consequence. Do not invent questions. If none exists, write "No decision needs you now."

$ARGUMENTS
