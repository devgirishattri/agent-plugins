---
name: lint
description: "Lint the memory store's frontmatter, schema, and index for defects (read-only)."
---

# Lint

When this skill is invoked, run the helper directly and return only its
formatted result or the shortest actionable failure.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Substitute that absolute path
literally below; never infer it from the working directory or hardcode a
marketplace cache version.

Run exactly one literal Bash segment (no `export`/`env`/assignment prefix,
command substitution, chaining, piping, or redirection):

```bash
bash "<PLUGIN_ROOT>/scripts/memory-lint.sh" [--store "<path>"]
```

Pass `--store "<path>"` only when the user supplied one; otherwise omit it and
let the helper resolve the store. Exit `0` means no ERROR-level finding,
although ADVISORY/WARN rows may exist; `2` is usage; `3` is resolution; `4` is
integrity or schema ERROR. Relay non-zero stderr verbatim.

Each stdout row is `<LEVEL>\t<file>\t<message>`, with LEVEL in
`ERROR|ADVISORY|WARN`. Group findings by file, lead with ERROR rows, summarize
legacy migration advice, and report a clean store plainly. This skill is
report-only: never edit files based on its findings.
