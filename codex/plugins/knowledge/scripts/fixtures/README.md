# Retrieval evaluation corpus

`retrieval-eval.json` is a reviewed, synthetic, intent-labelled baseline for
measuring the memory retrieval surfaces. It is **data only**: it never changes
scoring, and it carries **no quality thresholds** — the harness reports, it
does not gate. Version bumps and metric gates are separate decisions.

The harness is `scripts/eval-retrieval.py` (Python standard library only, no
network). Typical run:

```
python3 codex/plugins/knowledge/scripts/eval-retrieval.py \
  --corpus codex/plugins/knowledge/scripts/fixtures/retrieval-eval.json \
  --scripts codex/plugins/knowledge/scripts \
  --modes search recall hook-off hook-on hook-selective \
  --repeats 3 --warmup 1 --timeout 30 --output report.json
```

It builds a throwaway store in a temporary git repository, writes every
corpus memory into it, runs `memory-lint.sh` over that store as a preflight
(a malformed fixture fails the run before any measurement), runs each case
through each mode, and prints one JSON report on stdout, or writes it to
`--output` instead of stdout when that flag is given. It clears every
`KNOWLEDGE_*` / `KM_*` variable first, so it can never read or write a real
store. The harness's own tests live in `scripts/test-eval-retrieval.py`.

## Corpus contract (`schema_version: 1`)

```
{
  "schema_version": 1,
  "memories": [ { slug, name, description, tags[], type, status, body } ],
  "cases":    [ { id, category, query, prompt, relevant[], rationale } ]
}
```

- **memories** become canonical v1 memory files (`schema_version: 1`,
  `metadata.type`, `status`, `created`/`updated`, `tags` as a block YAML
  list — the memory parser does not read an inline `[a, b]` list) that pass
  `memory-lint.sh`. `description` is a required schema field, so it is never
  empty here; the hook's empty-description handling is covered by
  `test-auto.sh`, not by this corpus. Explicit links are written as
  `[[slug]]` inside `body` and drive the graph cases.
- **query** is the search/recall argument, verbatim (it may use the
  `"phrase"` and trailing-`*` grammar). **prompt** is the natural-language
  text the hook receives on `UserPromptSubmit`; it must contain the intended
  terms as tokens of four or more characters that are not on the extractor's
  stop list, or the hook will never see them.
- **relevant** is the set of slugs that *answer the intent*. It is labelled by
  a reviewer, never derived from what the current scorer returns, and it is
  shared by every mode for the same case. Keep labels fixed when a mode
  misses; a miss is a measurement, not a labelling error. An empty list marks
  a negative case.
- **rationale** says why those slugs answer the intent (and why the obvious
  distractors do not). It is not a claim about how the scorer should rank.
- All names are synthetic (`ProjectA`/`ProjectB`, zephyr/quokka/widget
  vocabulary). Never add a real project, host, or person; the release
  privacy sweep scans this file whenever a non-empty denylist is configured.

## Held-out corpus

`retrieval-eval-holdout.json` is a second, frozen corpus (14 memories, 14
cases, distinct ProjectC/ProjectD marlin/osprey/gantry vocabulary sharing no
memory with the tuning set). Its labels were written before any selective
graph result existed and must never be tuned against; it exists to show
whether a change that helps the tuning set generalises. Cases probe graph
routing from both sides: a dependency link with no shared target token, the
same seed with an unrelated link, factual lookup versus how-to, an archived
neighbour, an inbound-only link, an explicit previous-model request, a
superseded neighbour, an exploratory question, a link sentence that merely
mentions a prompt word, and negatives.

Known limitation, measured (single repeat, hook modes). Tuning set:
`hook-selective` recall@5 0.958 and returned precision 0.630, against 0.958
and 0.526 for the unfiltered `hook-on` — every noise expansion on a positive
case is gone, c26 is kept, and the negative c28 still gains its neighbour
because "promotion" appears verbatim in the link sentence. Held-out set:
`hook-selective` equals `hook-off` (recall@5 0.958, returned precision 0.535)
while `hook-on` reaches recall 1.000 at returned precision 0.486. Selective
drops every held-out expansion, including the one relevant one, h01, whose
link sentence overlaps the prompt only as `ship`/`Shipping`, which the
exact-or-six-letter-prefix rule cannot match. This says nothing about unseen
data in general, only about these 14 cases.
The rule is deliberately not loosened: a stem match that joins those two
also joins `shipped`/`shipping` in a negative held-out case and re-admits
noise. Run both corpora when changing the graph tier.

## Categories in the baseline

28 cases over 18 memories: slug, name, tags-only, body-only, multi-relevant,
phrase, prefix, degraded fallback, stale-intent, negatives (unrelated,
zero-overlap, a stop-word-heavy prompt whose one surviving token matches
nothing, and one with strong lexical overlap that asks for a detail the store
does not hold), distractors sharing a tag,
graph-helpful, graph-harmful, type-field, user/feedback types,
stop-word-heavy prompt, two-weak-body-terms, and a hyphenated extractor token.

**Coverage construction.** Cases c26 and c27 exist specifically to isolate
graph expansion: their linked memory shares no scored query atom or
extracted prompt term with the case (only ordinary stop words), so no
lexical mode can reach it and any difference between
`hook-off` and `hook-on` is the graph alone (c26 links a relevant entry, c27
an irrelevant one). The earlier c15/c16 remain as labelled even though their
targets are also reachable lexically. Graph rows never displace direct rows,
so a graph case also needs the direct seeds to leave room under the hook's
result limit (default 5); prompts for those cases avoid the broad `widget`
tag for that reason.

## Modes

| Mode | Command | Rows |
|---|---|---|
| `search` | `memory-search.sh --limit 5 <query>` | TSV slugs (column 2) |
| `recall` | `memory-search.sh --recall --limit 5 <query>` | `## <slug> (...)` headings |
| `hook-off` | `inject-recall.sh --prompt` with `KNOWLEDGE_AUTO_RECALL=prompt`, limit 5, terms 4, budget 4000 | `- [slug]` rows |
| `hook-on` | same, plus `KNOWLEDGE_AUTO_RECALL_GRAPH=true` and `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE=all` (the unfiltered legacy expansion, kept as the baseline) | `- [slug]` rows, related included |
| `hook-selective` | same, plus `KNOWLEDGE_AUTO_RECALL_GRAPH=true` and `KNOWLEDGE_AUTO_RECALL_GRAPH_MODE=selective` (the default when the graph is enabled) | `- [slug]` rows, only link-evidenced active outgoing neighbours |

Stdin is always provided (the hook reads its JSON there) and every call has a
timeout. A timeout, a helper error, or nondeterministic output aborts the
whole run with a message on stderr and exit status 1; no partial report is
written.

## Metrics

Per case and mode, over the retrieved slug list in output order:

- **precision@5** = relevant slugs among the first five / 5 (fixed
  denominator; empty slots count against nothing but also earn nothing).
- **returned_precision_at_5** = relevant slugs among the first five /
  min(rows returned, 5). This is the number that moves when a mode adds
  non-relevant rows without displacing relevant ones (the graph-harmful
  cases): P@5 can stay flat while returned_precision_at_5 falls. A positive
  case that returns zero rows scores 0; it is `null` for negative cases.
- **recall@5** = relevant slugs among the first five / |relevant|.
- **no-hit accuracy** (negative cases only) = 1 when the mode returns zero
  rows. For `search`/`recall` a degraded fallback that returns rows counts as
  a miss. Negatives are excluded from the macro P/R averages.
- **latency** = wall time of the subprocess, `--repeats` timed runs after
  `--warmup` untimed ones, reported as median and nearest-rank p95. It is
  informational only: it includes interpreter start-up and depends on the
  machine, so it is never asserted.
- **bytes** = raw UTF-8 stdout size per run. The hook's `_cap` is a byte cap;
  `memory-search.sh`'s budget is a character cap (equal on ASCII output).
- **determinism**: the full stdout of every repetition must be identical
  (not only the slug order); a difference aborts the run (see above).

The report keeps the full retrieved list (not just the top five) once per
case and mode, with only the time and byte samples recorded per repetition.

## Adding a case

1. Write the memory files first if the case needs new vocabulary; keep every
   term synthetic and avoid the `widget` tag unless a distractor is the point.
2. Label `relevant` from the intent before running anything, and write the
   prompt the way a user would actually phrase it.
3. Run the harness once and read the rows for that case. A miss is a
   measurement: do not retune the prompt or the label to improve the number.
   Prompts that lose their terms to the extractor's stop list or four-character
   minimum are part of what the corpus measures; keep them.
4. State the rationale in terms of which entries answer the intent.
