# Automatic recall / capture hooks (opt-in, OFF by default)

Beyond the agent-invoked `recall` and `remember` surfaces, the plugin ships hook-driven **automatic** recall and capture-nudge. Both are OFF unless you opt in with an environment variable (inherited at launch). Prompt-time injection still needs latency and false-positive tuning before it can be on by default.

All injected content is framed as untrusted background context. It is never instructions or policy. Every hook fails silently. A hook never breaks or stalls a session.

## `KNOWLEDGE_AUTO_RECALL`

This variable selects WHICH of the two injections run. Values are case-insensitive:

| Value | Injection |
|---|---|
| `1`, `yes`, `on`, `true`, `all`, `both` | Both |
| `session`, `session-start`, `index` | The SessionStart bounded `MEMORY.md` index only |
| `prompt`, `recall`, `user-prompt` | The per-prompt recall only |
| unset, `0`, `no`, `off`, `false` | Nothing |
| Any other non-empty value | Both |

- SessionStart injects the bounded index as always-on background.
- UserPromptSubmit extracts salient terms from the prompt. It qualifies aggregate lexical hits (a strong field score or two distinct prompt terms). It injects the top-N.

Tunables:
- `KNOWLEDGE_AUTO_RECALL_LIMIT`: top-N (default 5).
- `KNOWLEDGE_AUTO_RECALL_TERMS`: maximum terms queried (default 4). This bounds per-prompt latency.
- `KNOWLEDGE_AUTO_RECALL_BUDGET`: output byte cap (default 4000).
- `KNOWLEDGE_AUTO_RECALL_GRAPH`: strict opt-in. `1`, `yes`, `on`, or `true` enable it. All other values are OFF.
- `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE`: exactly `selective` or `all`. Unset or empty means `selective`. Any other value disables the graph tier only.

### Graph expansion (opt-in)

In `selective` mode, the graph tier is a conservative noise filter. It is not a router. The top two direct seeds can add at most two neighbours at depth one. A neighbour qualifies only when all four conditions hold:
1. The link is an *outgoing* `[[slug]]` link of the seed, written in canonical `lowercase_snake_case`. The tier does not follow an alias or a drifted spelling.
2. The sentence around the link contains one of the queried prompt terms. To find the sentence, the tier strips the link names. It splits at `.`, `!`, `?`, or `;` followed by whitespace, or at any newline. A prompt term is a normalised lowercase token of four or more characters. The match is exact, or it is a shared six-letter prefix for words of six or more letters, such as `promote` and `promotion`.
3. The neighbour is `active`.
4. The direct rows leave room under the result limit.

The row prints that evidence as `related via [[seed]]; link matched: <term>`. `term~word` marks a prefix match. A prefix match is a surface-form hit, not a semantic inference.

The helper is `scripts/recall-graph.py`. It reads at most two seed bodies. It never follows symlinks. It never touches the network.

`all` restores the earlier unfiltered expansion. It follows inbound and outbound neighbours and demotes stale ones instead of dropping them. It exists as the baseline for the evaluation corpus.

Measured results on the shipped corpora (`scripts/fixtures/`):
- On the tuning set, `selective` removes every noise expansion that the unfiltered mode added to a positive case. It keeps the one relevant expansion. One negative case still gains a neighbour, because its link sentence contains a prompt word verbatim.
- On the 14-case held-out set, `selective` removes every expansion, including the one relevant expansion. The link sentence of that expansion overlaps the prompt only as `ship` and `Shipping`. The exact-or-six-letter-prefix rule cannot match these words. On that held-out set, `selective` therefore scores the same as graph-off.

The prompt terms that can justify a link are the same `KNOWLEDGE_AUTO_RECALL_TERMS` that the direct queries use.

### Row format

Direct rows end in `(matched: term(field,field);term2(field))`. This is the scorer's explanation of which fields each distinct prompt term hit, in queried-term order. A dotted or hyphenated term can split into several atoms. The explanation lists each atom. Related rows keep the concise `related via [[seed]]` provenance and the link evidence above. Script: `scripts/inject-recall.sh`.

### Which value to use

- On Claude, `autoMemoryDirectory` can point at this store. The harness then already loads `MEMORY.md` every session. In that case `1` injects a verbatim duplicate index (about 691 tokens, paid twice). Prefer `prompt`. It keeps the per-turn recall that nothing else provides.
- Codex has no equivalent setting. `1` is correct there.

## `KNOWLEDGE_CONSOLIDATE_NUDGE=1`

This is a Stop hook. When the capture inbox has pending candidates, it surfaces ONE reminder to run `/knowledge:consolidate`.

- It emits the reminder as a NON-BLOCKING Claude Stop JSON `hookSpecificOutput.additionalContext`. Claude Stop hooks discard plain stdout.
- It checks `stop_hook_active`, so it can never loop.
- It is a nudge only. It never writes. It never consolidates automatically.
- Script: `scripts/nudge-consolidate.sh` (invoked with `--stop-json`).

## Autonomous capture (Claude-only, opt-in via snippet)

Autonomous capture is a `type:"prompt"` `Stop` hook that you add to your `settings.json`. See `assets/capture-stop-hook.md`. Its *presence* is the opt-in. The default `hooks/hooks.json` of the plugin ships **no** autonomous-capture hook, so fresh installs stay silent.

How it works:
- A small model evaluates the hook. It returns `{"ok":true}` and ends the turn **silently** in two cases: `stop_hook_active` is set (loop guard), or nothing durable was learned. Otherwise it returns `{"ok":false,"reason":…}`, which feeds the capture instruction back to the agent.
- The agent stages 0–N structured candidates. It routes them through the shared enforcement wrapper `scripts/memory-auto-capture.sh`.
- The wrapper caps count and bytes, rejects secrets, and does a cheap duplicate check. It delegates each accepted candidate to `memory-remember.sh --staged`. It writes ONLY to the capture inbox.
- `/consolidate` stays the persist gate. Nothing is written to authoritative memory automatically.

Known noise:
- An `ok:false` turn renders a red `Stop hook error` line, exactly like a `{"decision":"block"}` command hook. The identifier is the *entire* hook prompt.
- Only the `ok:true` path is silent. The line appears on turns where the hook judges something worth capturing.
- The line is not suppressible. If this noise matters, keep the `reason` short.

Tunables (environment):
- `KNOWLEDGE_AUTO_CAPTURE_LIMIT`: maximum accepted per pass (default 3).
- `KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING`: skip when the inbox has `>=` this many candidates (default 20).
- `KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES`: per-candidate byte cap (default 4096).

There is no `KNOWLEDGE_AUTO_CAPTURE` env gate and no default command hook.

On **Codex**, plugin hooks are command-only and cannot return `ok:false`. Autonomous Stop-capture is therefore not offered there. Use the manual capture bridge below.

## Capture bridge

`assets/capture-snippet.md` is the paste-into-AGENTS.md instruction. It is the companion to the recall bridge. It tells the agent to run `/knowledge:remember` mid-task and `/knowledge:consolidate` at session end.
