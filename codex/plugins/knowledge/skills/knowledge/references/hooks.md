# Recall and capture: implicit skills and opt-in hooks

`recall` and inbox-only `remember` support implicit selection during work.
Read their skills for bounded queries and evidence-backed capture. Skill selection
is best effort, with no guarantee of activation. Beyond those surfaces, the plugin ships
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
  inbox has pending candidates, prints ONE reminder to run
  `$knowledge:consolidate`. Nudge only — it never writes and never
  auto-consolidates. Script: `scripts/nudge-consolidate.sh`.
- **Implicit capture (0.5)** — both providers may select `remember` when a
  verified reusable lesson or user preference emerges. It stages
  `source: auto_capture` plus `evidence`, then invokes
  `memory-auto-capture.sh --staged <file>`. The writer stamps originating
  session/pane; model-supplied origins are rejected. Capture stays inbox-only.
  `KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT` (default 5) caps pending automatic
  candidates per session under the writer lock; consolidation frees capacity.
  Missing identity uses a shared unknown bucket. Count/byte/secret-pattern and
  duplicate checks remain in effect. This is not a lifetime capture budget.
- **Claude Stop capture** remains an optional prompt-hook snippet at
  `plugins/knowledge/assets/capture-stop-hook.md`. It must stage evidence too.
  Codex does not run prompt/agent hook handlers. Do not force a continuation on
  every Stop just to capture memory; SessionEnd cannot run a full Distill pass.
  The retired `KNOWLEDGE_AUTO_CAPTURE` variable remains unused.
- **Strict-v1 compatibility** — implicit capture through the wrapper needs
  session-workspace 0.11.1's reviewed `--staged FILE` helper grammar. Older
  harnesses refuse it; report that limitation, never bypass the harness.
- **Capture bridge** — `assets/capture-snippet.md` remains optional guidance
  for environments whose skill selection misses captures. Do not require the
  user to repeatedly invoke remember.

The durable-write surfaces `docs-create`, `init`, `consolidate`, and
`promote` retain explicit-only selection. A user-directed Distill batch may
compose docs-create and consolidate with the exact approved diffs, preserving
their role, CAS and validation gates. Remember is implicitly selectable only
for guarded inbox capture; cleanup still needs explicit user direction.

Direct prompt hits report scored terms and their matching fields, such as
`(matched: redis(name,tags);tls(body))`, in queried-term order. Related hits include the seed and, in selective mode, matching link-text evidence.
Explanations count toward the existing byte budget; direct matching thresholds
and ordering are unchanged.
