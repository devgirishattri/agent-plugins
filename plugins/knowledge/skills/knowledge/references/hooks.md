# Automatic recall / capture hooks (opt-in, OFF by default)

Beyond the agent-invoked `recall`/`remember` surfaces, the plugin ships
hook-driven **automatic** recall and capture-nudge. Both are OFF unless you
opt in with an environment variable (inherited at launch), because prompt-time
injection still needs latency / false-positive tuning before it is on by
default. All injected content is framed as
untrusted background context, never instructions/policy, and every hook fails
silently (never breaks or stalls a session).

- **`KNOWLEDGE_AUTO_RECALL`** — selects WHICH of the two injections run
  (case-insensitive): `1`/`yes`/`on`/`true`/`all`/`both` = both;
  `session`/`session-start`/`index` = the SessionStart bounded `MEMORY.md`
  index only; `prompt`/`recall`/`user-prompt` = the per-prompt recall only;
  unset/`0`/`no`/`off`/`false` = nothing. Any other non-empty value means both. SessionStart injects the bounded index as
  always-on background; UserPromptSubmit extracts salient terms from the
  prompt, qualifies aggregate lexical hits (a strong field score or two
  distinct prompt terms), and injects the top-N. Tunables:
  `KNOWLEDGE_AUTO_RECALL_LIMIT` (top-N, default 5),
  `KNOWLEDGE_AUTO_RECALL_TERMS` (max terms queried, default 4 — bounds
  per-prompt latency), `KNOWLEDGE_AUTO_RECALL_BUDGET` (output byte cap,
  default 4000), `KNOWLEDGE_AUTO_RECALL_GRAPH` (strict opt-in: `1`, `yes`,
  `on`, or `true`; all other values are OFF), and
  `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE` (exactly `selective` or `all`; unset
  or empty means `selective`; any other value disables the graph tier only).

  **Graph expansion (opt-in).** In `selective` mode the graph tier is a
  conservative noise filter, not a router: the top two direct seeds may add
  at most two neighbours at depth one, but only along the seed's *outgoing*
  `[[slug]]` links written in canonical `lowercase_snake_case` (an alias or
  drifted spelling is not followed) whose surrounding sentence (link names
  stripped; split at `.`, `!`, `?`, or `;` followed by whitespace, or at any
  newline) contains one of the queried prompt terms (normalised lowercase
  tokens of four or more characters) — exactly, or by a shared six-letter
  prefix for words of six or more letters, such as `promote`/`promotion` —
  and only when the neighbour is
  `active` and the direct rows leave room under the result limit. That
  evidence is printed on the row as `related via [[seed]]; link matched:
  <term>` (`term~word` marks a prefix match: a surface-form hit, not a
  semantic inference). The helper is `scripts/recall-graph.py`; it reads at
  most two seed bodies, never follows symlinks, and never touches the
  network. `all` restores the earlier unfiltered expansion (inbound and
  outbound neighbours, stale ones demoted rather than dropped) and exists as
  the baseline for the evaluation corpus. Measured on the shipped corpora
  (`scripts/fixtures/`): on the tuning set, selective removes every noise
  expansion the unfiltered mode added to a positive case and keeps the one
  relevant expansion (one negative case still gains a neighbour, because
  its link sentence contains a prompt word verbatim); on the 14-case
  held-out set it removes every expansion, including the one relevant one,
  whose link sentence overlaps the prompt only as `ship`/`Shipping`, which
  the exact-or-six-letter-prefix rule cannot match — so on that held-out
  set it scores the same as graph-off. The prompt terms that can justify a link are the same
  `KNOWLEDGE_AUTO_RECALL_TERMS` used for the direct queries.

  Direct rows end in `(matched: term(field,field);term2(field))` — the
  scorer's own explanation of exactly which fields each distinct prompt
  term hit, in queried-term order (a dotted or hyphenated term can split
  into several atoms, each listed); related rows keep the concise
  `related via [[seed]]` provenance plus the link evidence above. Script:
  `scripts/inject-recall.sh`.

  **Which value to use.** On Claude, if `autoMemoryDirectory` points at this
  store the harness already loads `MEMORY.md` every session, so `1` injects a
  verbatim duplicate index (~691 tokens paid twice) — prefer `prompt`, which
  keeps the per-turn recall nothing else provides. Codex has no equivalent
  setting, so `1` is correct there.

- **`KNOWLEDGE_CONSOLIDATE_NUDGE=1`** — a Stop hook that, when the capture
  inbox has pending candidates, surfaces ONE reminder to run
  `/knowledge:consolidate`. It emits the reminder as a NON-BLOCKING Claude Stop
  JSON `hookSpecificOutput.additionalContext` (Claude Stop hooks discard plain
  stdout), guarded on `stop_hook_active` so it can never loop. Nudge only — it
  never writes and never auto-consolidates. Script:
  `scripts/nudge-consolidate.sh` (invoked with `--stop-json`).
- **Autonomous capture (Claude-only, opt-in via snippet)** — a
  `type:"prompt"` `Stop` hook you add to your `settings.json`; see
  `assets/capture-stop-hook.md`. Its *presence* is the opt-in — the plugin's
  default `hooks/hooks.json` ships **no** autonomous-capture hook, so fresh
  installs stay silent. A small model evaluates the hook and returns
  `{"ok":true}` — ending the turn **silently** — when `stop_hook_active` is set
  (loop guard) or nothing durable was learned; otherwise `{"ok":false,"reason":…}`
  feeds the capture instruction back to the agent. An `ok:false` turn renders
  a red `Stop hook error` line, exactly like a `{"decision":"block"}` command
  hook, with the *entire* hook prompt as the identifier; only the `ok:true`
  path is silent, so the line appears on turns where something is judged worth
  capturing. The line is not suppressible; keep the `reason` short if that
  noise matters.
  The agent stages 0–N structured candidates and routes them through the shared
  enforcement wrapper `scripts/memory-auto-capture.sh`, which caps count/bytes,
  rejects secrets, does a cheap duplicate check, and delegates each accepted one
  to `memory-remember.sh --staged` — writing ONLY to the capture inbox.
  `/consolidate` stays the persist gate; nothing is written to authoritative
  memory automatically. Tunables (environment):
  `KNOWLEDGE_AUTO_CAPTURE_LIMIT` (max accepted per pass, default 3),
  `KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING` (skip when inbox `>=` this, default 20),
  `KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES` (per-candidate byte cap, default 4096).
  There is no `KNOWLEDGE_AUTO_CAPTURE` env gate and no default command hook. On **Codex**,
  plugin hooks are command-only and cannot return `ok:false`, so autonomous
  Stop-capture is not offered there — use the manual capture bridge below.
- **Capture bridge** — `assets/capture-snippet.md` is the paste-into-AGENTS.md
  instruction (companion to the recall bridge) telling the agent to
  `/knowledge:remember` mid-task and `/knowledge:consolidate` at session end.
