# Automatic recall / capture hooks (0.2 — opt-in, OFF by default)

Beyond the agent-invoked `recall`/`remember` surfaces, the plugin ships
hook-driven **automatic** recall and capture-nudge. Both are OFF unless you
opt in with an environment variable (inherited at launch), because prompt-time
injection still needs latency / false-positive tuning before it is on by
default (per the spec's 0.2 roadmap gate). All injected content is framed as
untrusted background context, never instructions/policy, and every hook fails
silently (never breaks or stalls a session).

- **`KNOWLEDGE_AUTO_RECALL`** — selects WHICH of the two injections run
  (case-insensitive): `1`/`yes`/`on`/`true`/`all`/`both` = both;
  `session`/`session-start`/`index` = the SessionStart bounded `MEMORY.md`
  index only; `prompt`/`recall`/`user-prompt` = the per-prompt recall only;
  unset/`0`/`no`/`off`/`false` = nothing. Any other non-empty value means both,
  so pre-0.2.1 settings keep working. SessionStart injects the bounded index as
  always-on background; UserPromptSubmit extracts salient terms from the
  prompt, qualifies aggregate lexical hits (a strong field score or two
  distinct prompt terms), and injects the top-N. Tunables:
  `KNOWLEDGE_AUTO_RECALL_LIMIT` (top-N, default 5),
  `KNOWLEDGE_AUTO_RECALL_TERMS` (max terms queried, default 4 — bounds
  per-prompt latency), `KNOWLEDGE_AUTO_RECALL_BUDGET` (output char cap,
  default 4000), and `KNOWLEDGE_AUTO_RECALL_GRAPH` (strict opt-in: `1`,
  `yes`, `on`, or `true`; all other values are OFF). When enabled, at most
  two direct seeds add at most two active/stale-demoted inbound or outbound
  `[[slug]]` neighbors at depth one, within the same result and budget caps.
  Related rows include concise `related via [[seed]]` provenance. Script:
  `scripts/inject-recall.sh`.

  **Which value to use.** On Claude, if `autoMemoryDirectory` points at this
  store the harness already loads `MEMORY.md` every session, so `1` injects a
  verbatim duplicate index (~691 tokens paid twice) — prefer `prompt`, which
  keeps the per-turn recall nothing else provides. Codex has no equivalent
  setting, so `1` is correct there.

- **`KNOWLEDGE_CONSOLIDATE_NUDGE=1`** — a Stop hook that, when the capture
  inbox has pending candidates, prints ONE reminder to run
  `$knowledge:consolidate`. Nudge only — it never writes and never
  auto-consolidates. Script: `scripts/nudge-consolidate.sh`.
- **Autonomous capture (0.3)** — **not offered on Codex.** Codex plugin hooks
  support only `type:"command"`, which can force a capture pass at `Stop` solely
  via `{"decision":"block",…}`; Codex renders that as a blocked-hook line on
  **every** turn, so a default autonomous-capture Stop hook is pure noise. It has
  therefore been retired from the Codex `hooks/hooks.json` (and the paired
  `KNOWLEDGE_AUTO_CAPTURE` env gate). On Codex, capture memory manually via the
  bridge below (`$knowledge:remember` mid-task, `$knowledge:consolidate` at
  session end). Autonomous Stop-capture ships on Claude only, as an opt-in
  `type:"prompt"` snippet — the Claude tree's
  `plugins/knowledge/assets/capture-stop-hook.md`, not shipped in this Codex tree
  — that returns the silent `{"ok":…}` shape Codex hooks cannot. The shared enforcement wrapper
  `scripts/memory-auto-capture.sh` (caps count/bytes, rejects secrets, dedups,
  inbox-only) is still present and remains the sole write path whenever candidates
  are staged; `$knowledge:consolidate` stays the persist gate.
- **Capture bridge** — `assets/capture-snippet.md` is the paste-into-AGENTS.md
  instruction (companion to the recall bridge) telling the agent to
  `$knowledge:remember` mid-task and `$knowledge:consolidate` at session end.

The five write-capable agent surfaces — `docs-create`, `init`, `remember`,
`consolidate`, and `promote` — are explicit-only on both providers. Their Codex
skills set `policy.allow_implicit_invocation: false`; invoke them only through
their corresponding `$knowledge:*` command.
