---
description: "Deterministic lexical ranked search over the memory store (read-only)"
argument-hint: "[--store <path>] [--limit N] [--json] [--explain] <query>"
allowed-tools: Bash(bash:*)
---

## Instructions

`memory-search.sh` is read-only. It never writes to the store. This command ranks the memory store alone. To search docs, memory, and context snapshots side by side, use `/knowledge:find`.

Run exactly one literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.sh" [--store <path>] [--limit N] [--json] [--explain] '<query>'
```

Build the query from `$ARGUMENTS`:
- Pass `--store <path>` only if the user supplied one. Otherwise omit it. The script then resolves the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`).
- Pass `--limit <n>` only if the user asked for a specific result count (default 10, hard cap 50).
- Pass `--json` only if the user wants the raw JSON object instead of the default TSV rows.
- Pass `--explain` when the user asks *why* something matched, or which field a term hit. It appends a sixth TSV column with the match provenance. With `--json`, the script accepts `--explain` and ignores it, because the JSON objects always carry the same data.
- **Always wrap the query text itself in single quotes**, verbatim as the user typed it. Keep any `"quoted phrase"` syntax and any trailing `*` prefix wildcard. The script implements its own tiny query language. `"..."` is a phrase. A trailing `*` is a prefix. Whitespace-separated terms are an implicit AND. There is no OR or NOT. Single quotes around the whole query keep those literal characters intact. Without them, the outer shell consumes the characters.
- If the query itself contains a single quote, tell the user that v1 does not support it. Do not guess at escaping.

Query grammar reference:
- Tokenization is lowercase and splits on non-alphanumeric characters.
- `"quoted text"` is one phrase atom. It is a substring match. Its words get no separate scoring unless they also appear on their own.
- A trailing `*` on a bare word is a prefix match.
- The scorer weights results by field: slug 8, name 6, tags 5, description 4, type 3, headings 2, backlink slugs 2, body 1. It sums the weights per matching field.
- `stale`, `superseded`, and `archived` files have their total halved (rounded down).
- Ordering is score descending, then slug ascending.
- The weights are published for writers as much as for readers. To make an entry reliably findable, put its load-bearing words in `tags` or `name` (weights 5 and 6), not only in prose.

## Exit codes

| Exit | Meaning | Next action |
|---|---|---|
| `0` | Success, including zero hits. An empty TSV result is normal, not an error. | Report the results. |
| `2` | Invalid query (empty after tokenization, or an unbalanced quote) or a bad `--limit`. | Report the stderr usage line. |
| `3` | The store could not be resolved. | Relay the stderr message. It suggests `/knowledge:init` when no store exists. |
| `4` | A store-integrity error: a slug collision, or a filename stem outside the safe `[A-Za-z0-9._-]` grammar. | Relay the stderr message. Stop. This is a data problem in the store. Retrying does not fix it. |

## Output

Default (TSV): one result per line, `<score>\t<slug>\t<type>\t<status>\t<description (first 120 chars)>`, highest score first.

- With `--explain`, a sixth column `<atom>(<field>,<field>);<atom2>(<field>)` names, per query atom in query order, exactly which fields that atom matched. Field names are as in the weights above, in weight order. Phrase atoms keep their quotes. Prefix atoms keep their `*`.
- `--json` emits one object `{"results":[...], "truncated":<n>}`. Each result also carries `file` (the bare basename) and `matches`. `matches` is always present. It holds the same provenance as a list of `{"atom": "...", "fields": [...]}` objects.
- On a degraded result, the provenance covers only the atoms of the winning subset. It never covers a dropped atom.
- Zero hits print nothing (TSV) or an empty `results` array (JSON). Say so plainly. Do not treat zero hits as a failure.
- If stderr contains a `truncated: <n> more` line, tell the user that more results exist than the output shows. Suggest raising `--limit` or narrowing the query.

Report to the user:
1. Lead with the result count.
2. Group or summarize the results. Do not dump raw TSV.
3. Cite slugs, so the user can run `/knowledge:recall` or open the file directly.

**Degraded fallback.** A query of 2 or more atoms can get zero full-query hits. The search then falls back automatically to the best-matching subset of atoms. Without this, the result would look the same as a zero for "nothing stored". A single-atom zero-hit query is never degraded. A query with at least one full-query hit is completely unaffected.

When the fallback happens:
- TSV gets one stderr line before any `truncated:` line: `degraded: 0 results for the full query; showing <N> for: <subset text>`.
- `--json` gains a top-level `"degraded": {"matched": "<subset text>", "dropped": "<dropped text>"}` object. The object is absent on the normal path. Its presence alone shows that the search widened the result set.
- Relay the degraded line or key to the user plainly. The exact query matched nothing. The results shown are a narrower substitute, not the full picture.

$ARGUMENTS
