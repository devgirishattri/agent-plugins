---
name: search
description: "Deterministic lexical ranked search over the memory store (read-only)."
---

# Search

Run only the accepted helper workflow below and return its formatted result or the shortest actionable failure.

## Instructions

Resolve `PLUGIN_ROOT` from this selected skill's installed absolute source path: it is the directory two levels above this `SKILL.md`. Substitute that absolute path literally in every helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

`memory-search.sh` is read-only: it never writes to the store. Run exactly one literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "<PLUGIN_ROOT>/scripts/memory-search.sh" [--store <path>] [--limit N] [--json] '<query>'
```

Build the query from `the user's arguments`:
- Pass `--store <path>` only if the user supplied one; otherwise omit it and let the script resolve the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`).
- Pass `--limit <n>` only if the user asked for a specific result count (default 10, hard cap 50).
- Pass `--json` only if the user wants the raw JSON object instead of the default TSV rows.
- **Always wrap the query text itself in single quotes**, verbatim as the user typed it — including any `"quoted phrase"` syntax or a trailing `*` prefix wildcard. The script implements its own tiny query language (`"..."` = phrase, trailing `*` = prefix, whitespace-separated terms = implicit AND, no OR/NOT); single-quoting the whole query keeps those literal characters intact instead of letting the outer shell consume them. If the query itself contains a single quote, tell the user that's not supported in v1 rather than guessing at escaping.

Query grammar reference: lowercase + non-alphanumeric-split tokenization; `"quoted text"` is one phrase atom (substring match, no separate scoring for its words unless they also appear on their own); a trailing `*` on a bare word is a prefix match; results are weighted by field (slug 8, name 6, tags 5, description 4, type 3, headings 2, backlink slugs 2, body 1) and summed per matching field; `stale`/`superseded`/`archived` files have their total halved (rounded down); ordering is score desc then slug asc.

Exit codes: `0` success (including zero hits — an empty TSV result is normal, not an error); `2` invalid query (empty after tokenization, or an unbalanced quote) or bad `--limit` — report the stderr usage line; `3` the store could not be resolved (relay the stderr message, which suggests `$knowledge:init` when no store exists); `4` a store-integrity error (a slug collision or a filename stem outside the safe `[A-Za-z0-9._-]` grammar) — relay the stderr message and stop; this is a data problem in the store, not something to fix by retrying.

## Output

Default (TSV): one result per line, `<score>\t<slug>\t<type>\t<status>\t<description (first 120 chars)>`, highest score first. `--json` emits one object `{"results":[...], "truncated":<n>}` where each result also carries `file` (the bare basename). Zero hits print nothing (TSV) or an empty `results` array (JSON) — say so plainly rather than treating it as a failure. If stderr contains a `truncated: <n> more` line, mention that more results exist than were shown (raise `--limit` or narrow the query). Present results to the user grouped/summarized rather than dumping raw TSV; cite slugs so the user can `$knowledge:recall` or open the file directly.
