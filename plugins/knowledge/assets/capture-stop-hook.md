# Autonomous capture — opt-in `Stop` hook (Claude)

This is the **opt-in** bridge for the knowledge plugin's autonomous memory
capture on **Claude Code**. The plugin ships **nothing active** by default: a
fresh install never captures autonomously and never shows a Stop-hook line.
Adding the snippet below to your **user or project `settings.json`** is what
turns it on — the hook's *presence* is the opt-in (it replaces the old
`KNOWLEDGE_AUTO_CAPTURE` environment gate on Claude).

## Why a `type: "prompt"` hook (not `command`)

A `command` Stop hook can only force the agent to keep working by returning
`{"decision":"block", …}`, and Claude Code renders **every** such block as a red
`Stop hook error` line — on every turn the gate is on, whether or not anything
was worth capturing. There is no setting to restyle or suppress it.

A `type: "prompt"` Stop hook instead returns `{"ok": true}` or
`{"ok": false, "reason": …}`. On `ok:false` the `reason` is fed back to Claude
so it keeps working (to run one capture pass). On `ok:true` the turn ends
silently. A tiny model (Haiku by default) evaluates
the hook, so it can also self-gate: it returns `{"ok": true}` when
`stop_hook_active` is set (the loop guard) or when nothing durable was learned,
and only re-prompts when there is genuinely something to capture.

**Correction (verified 2026-07-31).** An earlier version of this document
claimed `ok:false` avoids the red error line. It does not: Claude Code renders
an `ok:false` prompt hook exactly like a blocked command hook — a red
`Stop hook error` — and it prints the **entire hook prompt** as the identifier,
so a single `ok:false` turn is a wall of text and looks like a failure even
though capture is working. The real gain over the retired command hook is the
silent `ok:true` path: the line now appears only on turns where the evaluator
judges something worth capturing, not on every turn. The line is not
suppressible by any setting. If that noise matters, keep the `reason` to a
one-line pointer at this file instead of inlining the full envelope below —
or don't install the hook and use `/knowledge:remember` manually.

## Install

Merge this into your `~/.claude/settings.json` (global) or a project
`.claude/settings.json`. If you already have a `Stop` array, add the object to
it rather than replacing it.

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "prompt",
            "prompt": "You are the gate for the knowledge plugin's opt-in autonomous memory capture, running as a Claude Code `Stop` hook. The Stop hook input JSON is: $ARGUMENTS\n\nReply with EXACTLY one JSON object and nothing else.\n- If the input field `stop_hook_active` is true, reply {\"ok\": true}. (Loop guard: the capture pass already ran this turn — never request it twice.)\n- If nothing durable and forward-looking was learned this session that is worth remembering — judging from the session's final assistant message in the input (the prompt-hook evaluator sees the Stop input, not the tool-call transcript, so err toward {\"ok\": true} unless the durable fact is evident) — reply {\"ok\": true}. Capturing nothing is the common, correct outcome; prefer {\"ok\": true} whenever you are unsure.\n- Otherwise reply {\"ok\": false, \"reason\": R} where R is the text between <<REASON>> and <</REASON>> below, copied VERBATIM (do not summarize, shorten, or alter it — the strict envelope must reach the agent intact):\n<<REASON>>\nknowledge auto-capture: before ending, do ONE bounded pass to capture durable, forward-looking memory from THIS session — then stop.\n\nCapture ONLY (high-confidence): a user preference or standing instruction; a repo/project invariant, architecture decision, workflow rule, or environment fact; a resolved root cause or reusable fix; feedback that changes future behavior; an external tracker/document pointer. SKIP transcripts/summaries, transient todos, speculation, secrets, and anything already in memory unless this session materially changed it. It is completely fine to capture NOTHING.\n\nTo capture: write each item as its own staged candidate file in a temp location (under the strict-v1 session-workspace harness, a permitted scratch path inside this pane's checkout), using EXACTLY this envelope (copy the structure; the enum values are strict and a wrong value makes the whole candidate rejected):\n---\nsource: auto_capture\nsensitivity: normal\nevidence: file:line, commit, or a short quoted user statement\nproposed:\n  schema_version: \"1\"\n  name: Short display name (free text, not a slug)\n  description: One-line description of the fact\n  metadata:\n    type: project\n  tags:\n    - optional-tag\n---\n**Why:** why this matters for future work.\n\n**How to apply:** the concrete action to take.\n\nSTRICT rules for the fields (a wrong value = rejected):\n- evidence: REQUIRED for source auto_capture; a single line of at most 300 bytes — an observed file:line or function, a commit, a tool result, or a short quoted user statement. It is a provenance claim only; the writer never verifies it. Do NOT add origin_session or origin_pane (writer-assigned).\n- sensitivity: MUST be exactly \"normal\" or \"sensitive\" (nothing else).\n- metadata.type: MUST be exactly one of \"user\", \"feedback\", \"project\", \"reference\" (e.g. use \"project\" for a repo/project invariant; NOT \"project_invariant\" or any other value).\n- tags: OPTIONAL, and it is a sibling of metadata under proposed (proposed.tags) — do NOT nest tags under metadata.\n- QUOTING: an UNQUOTED value must not contain a \" character, or the whole candidate is rejected (parser error: unexpected quote in unquoted scalar). If a value contains a double quote, wrap the WHOLE value in \"...\" — inner quotes then pass through as-is. Colons and apostrophes are safe unquoted. This bites most often when the fact is about JSON, hook shapes, or config syntax.\n- name is free display text; description is a single line; the body needs both **Why:** and **How to apply:**.\n\nThen run ONCE the knowledge plugin's enforcement wrapper (it auto-resolves this repo's store and writes ONLY to the capture inbox; it does NOT persist): bash <knowledge-plugin>/scripts/memory-auto-capture.sh --staged <file-1> --staged <file-2> (one --staged per candidate file)\nAfter the wrapper returns, remove each staged file you created: one separate rm -f \"<file>\" command per literal path, never a glob, a directory, a store path, or a user-named or supplied file. If a removal is denied or fails, report the remaining path; do not retry or bypass.\nDo not call memory-remember.sh or any writer directly. After the wrapper runs (or if there is nothing to capture), stop.\n<</REASON>>"
          }
        ]
      }
    ]
  }
}
```

## Notes

- **Re-copy after upgrading.** The hook lives in your settings file as a copy.
  Plugin updates never change it. After you update knowledge, replace the
  `prompt` string with the current one above. A stale copy uses `--batch-dir`,
  lacks `evidence: REQUIRED`, or lacks the `rm -f` cleanup line. Only a
  candidate without evidence makes the wrapper report
  `rejecting candidate without an evidence: field`. A missing cleanup line
  only leaves staged files behind.
- **Enforcement is unchanged.** The reason routes every candidate through the
  shared `scripts/memory-auto-capture.sh` wrapper — the *sole* write path — which
  caps count/bytes, rejects secrets and candidates lacking `evidence:`, dedups,
  honours `MAX_PENDING` and the per-session pending cap, and writes
  **only** to `.agents/memory/.inbox/`. Nothing is persisted automatically;
  `/knowledge:consolidate` stays the persist gate. The wrapper auto-resolves the
  store, so no path needs to be baked into the snippet. If you prefer a fixed
  path over letting the agent locate the script, replace `<knowledge-plugin>`
  with your installed plugin directory
  (`~/.claude/plugins/cache/<marketplace>/knowledge/<version>`).
- **Tunables** (environment, optional): `KNOWLEDGE_AUTO_CAPTURE_LIMIT` (max
  accepted per pass, default 3), `KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING` (skip when
  the inbox already holds `>=` this many, default 20),
  `KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES` (per-candidate byte cap, default 4096),
  `KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT` (max PENDING auto_capture candidates
  per originating session, default 5 — a pending limit, not a lifetime budget).
  Numeric values are bounded decimals 0..999999; anything else uses the default.
- **No automatic consolidation.** This hook and implicit `remember` only queue
  inbox candidates. Neither runs `consolidate`; it stays user-run. The user may
  ask to "wrap up this session" to run `distill` (one approved batch).
- **Loop guard.** The hook returns `{"ok": true}` when `stop_hook_active` is
  true, so a capture pass never re-prompts itself; Claude Code's
  `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP` (default 8) is the additional backstop.
- **Consolidation nudge.** The plugin's default `Stop` hook,
  `scripts/nudge-consolidate.sh`, is separate and still opt-in via
  `KNOWLEDGE_CONSOLIDATE_NUDGE=1`; it surfaces a non-blocking reminder when the
  inbox has pending candidates and never blocks or errors.
- **Codex.** Codex plugin hooks support only `type: "command"`, which cannot
  return the silent `ok:false` shape, so autonomous Stop-capture is **not**
  offered on Codex — a command Stop hook there renders a blocked-hook line every
  turn. On Codex, use the manual capture bridge (`assets/capture-snippet.md`,
  i.e. `$knowledge:remember` mid-task + `$knowledge:consolidate` at session end).
