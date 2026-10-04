---
description: "Bootstrap a new .agents/memory/ store for this repository"
argument-hint: "[--store <path>]"
allowed-tools: Read, Edit, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

`init.sh` is a two-call PLAN/APPLY protocol. No state carries between the calls. The target resolution is deterministic, so both calls derive the same path. Follow these steps in order. Stop immediately if any step fails.

1. **Plan.** Run exactly one literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect. Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" [--store <path>]
   ```

   | Result | Meaning | Next action |
   |---|---|---|
   | Exit `0` with a line `(already covered by .gitignore — re-run with --apply)` | The `.gitignore` coverage of the store is already in place. | Skip to step 3. |
   | Exit `0` with a `--- a/...` / `+++ b/...` / `@@` / `+<path>/` diff after the `target: <path>` line | The diff is the proposed `.gitignore` addition. | Continue to step 2. |
   | Exit `3` | Not inside a git repository, or another resolution failure. | Relay the stderr message verbatim. Stop. |

2. **Apply the proposed `.gitignore` line.** Use the Read and Edit tools, not Bash. Add the exact proposed line (the `+<path>/` content, for example `.agents/memory/`) to the `.gitignore` file named in the `+++ b/<path>` line of the diff. Create the file if it does not exist. Show the user the diff you applied.

3. **Bootstrap.** Run exactly one literal Bash segment. Use the SAME `--store` argument (if any) as in step 1, plus `--apply`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" [--store <path>] --apply
   ```

   | Result | Meaning | Next action |
   |---|---|---|
   | Exit `0` with `created: <path>` | The store now exists (empty `MEMORY.md`, `0700`/`0600` permissions). | Report `created`. |
   | Exit `0` with `already initialized: <path>` | Idempotent no-op. The store was already healthy. | Report that no action was needed. |
   | Exit `3` | The `.gitignore` still does not cover the target. Your edit in step 2 might not match, or you skipped it. | Relay the message. Stop. Do not retry with a different path. |
   | Exit `6` | Reviewer-role refusal, or an unresolved fleet identity inside tmux. This is expected behavior in a `*-reviewer` pane, not a bug. | Relay the single stderr line verbatim. Stop. |
   | Exit `4` | A store-integrity problem, for example an unsafe pre-existing path. | Relay the message verbatim. Stop. |

Never invoke `memory-write.sh bootstrap` directly from this command. Always go through `init.sh`, so that the gitignore-coverage gate stays in force.

$ARGUMENTS
