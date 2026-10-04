# Plugin writing guide

**Date:** 2026-10-04
**Scope:** Human and agent instructions in both provider trees, including skills, command wrappers, and explanatory assets.

Use this guide when creating or changing procedural prose. It adapts selected
ASD-STE100 principles to this repository. It does not require the complete STE
dictionary or establish conformity with the standard.

## Write clear procedures

- Use active voice and name the actor when responsibility could be unclear.
- Start an action with an imperative verb. Put its prerequisite before the action.
- Give one instruction per sentence. Keep simultaneous actions together when separating them would change their meaning.
- Aim for at most 20 words in procedural sentences and 25 in descriptive sentences.
- Put alternatives and exit conditions in lists or tables when that makes them easier to compare.
- Use one term for each operation. Keep explanations separate from required actions.

These are review targets, not automatic rejection rules. Preserve a longer
sentence when splitting it would obscure scope, an exception, or a safety condition.
Code blocks, identifiers, paths, quoted protocol text, and tables need their own
review. Do not use a word-count score as evidence that a workflow works better.

## Preserve the workflow contract

Before editing, identify the actor, trigger, permission, action, failure response,
and completion evidence. After editing, check that each has the same meaning.
If the behavior must change, treat that change as implementation work and test it.

Preserve exact command names, flags, environment variables, schema fields,
exit codes, paths, and provider syntax. Keep permission boundaries and negative
requirements explicit. Do not replace domain terms merely because a general
dictionary does not contain them.

| Term | Meaning in these plugins |
|---|---|
| User approval | The user's authorization for a specified action or reviewed payload. Preserve any required timing, scope, and hash binding. |
| Check or verify | An agent or helper tests a fact, artifact, or condition. Verification does not grant permission. |
| Confirmation | A user decision when the workflow requires one. Keep literal flags such as `--confirmed` unchanged. |
| Candidate | An inbox draft awaiting review. A capture is not durable promotion. |
| Apply | Use the prescribed writer to make the authorized change. A proposal or successful wrapper exit alone does not prove application. |
| Unavailable, failed, unknown | Distinct outcomes. Preserve each workflow's retry and reporting rules. |

Review ambiguous uses of “may,” “can,” and “should” individually. Do not replace
them globally. A permission, capability, and recommendation are different claims.
Preserve required stops and their causes when turning exit-code prose into a table.

For example, split a purge instruction into these separate statements:

> Purge only after the user explicitly requests deletion. Do not infer this approval from automatic skill selection. Purge is destructive.

This example does not replace a skill's stricter approval or role requirements.

## Review and verification

1. Compare changed prose with the original contract and both provider versions.
2. Verify referenced commands and paths against current source.
3. Run relevant existing checks. For changed selection or approval behavior, use observable behavioral fixtures with positive and negative controls.
4. Record coverage and exceptions. Do not claim any STE conformity or measured model improvement from an editorial review.

Keep this authoring guide in the repository. Shipped skills must remain usable
without reading it. Avoid repeating this entire guide in each skill.

## User-facing reports

Apply these conventions where the skill permits an authored response. Keep
literal helper output, JSON envelopes, table schemas, and transport messages
unchanged when the skill requires exact output. Do not add a second summary to
a command that requires only the transport result.

Lead with the observed outcome. Include only the details needed for the next
decision: the affected artifact, checks completed, unresolved work, and the
next action. Omit empty sections. A short successful operation needs only a
short result; a partial operation needs per-item outcomes.

- For approval, state what will change and what the reply authorizes. Show the
  required exact payload, diff, and hash. A shorter explanation must not hide
  the review material or weaken the timing of approval.
- For failure, identify the failed operation, the observed reason, any effects
  already verified, and the permitted recovery action. Preserve required raw
  diagnostics. Do not invent a cause, imply zero effects from an error alone,
  or recommend retrying an operation with an unknown outcome.
- For a handoff, separate completed work from proposed work. Name the next
  action and its prerequisite. Retain stable item IDs and evidence links.
- For verification, identify the checked subject and the scope of the check.
  Report omitted checks. A test pass does not establish a production outcome.

Examples of authored explanations (not replacements for exact helper output):

| Situation | Clear report |
|---|---|
| Transport accepted a queued message | The message is queued. Recipient execution is not confirmed. |
| A write succeeded but notification failed | The task was updated. Notification failed. Retry only the notification through its authorized workflow. |
| A plugin cache matches the release | The installed files match the release. Restart the session to load them; activation is not yet verified. |
| Approval applies to one item | Approve item D1 to apply the displayed document diff. Items D2 and M1 remain pending. |
| Remote create timed out | The create outcome is unknown. Check for the existing item before sending another create request. |

## Shared technical terms

Use the exact domain term instead of a loose synonym. This vocabulary extends
the table above; it does not change any script's enums or output schema.

| Term | Use when |
|---|---|
| Capture | A candidate is written to the inbox; it is not yet authoritative memory. |
| Promote | The relevant writer installs reviewed knowledge at its destination. Source retirement is a separate operation when required by that workflow. |
| Dismiss | A candidate is archived with its content retained. Do not describe dismissal as deletion. |
| Delete or purge | The specified workflow removes data. Keep its explicit authorization requirement. |
| Queued, sent, replied | Report the state that the transport actually confirms. None alone proves that the recipient completed the task. |
| Installed | The package files are present in the installed location. |
| Active | The running session has loaded the intended version, with the required trust/configuration. Installation alone is insufficient evidence. |
| Verified | A named check passed for a named subject. State the check's limits. |
| Failed | The observed operation failed; report known partial effects separately. |
| Unknown | Available evidence does not establish the operation's outcome. |

## Advisory checks and comparisons

Run `python3 -B scripts/lint-plugin-prose.py --changed-from <commit>` to inspect
tracked Markdown changed since a known commit. Explicit file arguments also
include new files. With no arguments, it checks tracked skill, command, agent,
reference and asset Markdown plus this guide and README.

The checker flags sentence-length targets and a small list of avoidable word
choices. It is a heuristic, not an STE validator. It skips frontmatter, fenced
and inline code, headings, tables, quoted examples, and HTML comments. Technical
abbreviations and unusual Markdown can still produce false positives or missed
findings. Setext headings, multiline code spans, and lazy blockquote continuations are not fully
parsed. Frontmatter is recognized only with a closing marker in the first 101
lines and a field; malformed or longer frontmatter can be linted as prose.
Explicit paths can be outside the repository; parent-directory symlinks are
followed, but a symlink file itself is rejected. Review each advisory; do not auto-replace technical terms or split a
condition away from its action. Style findings return success; unreadable or
invalid inputs return a nonzero status. No file is modified.

Use the [comparison procedure](PROSE_EVALUATION.md) before claiming that wording
improves model behavior. Deterministic fixture checks can run without model
spend; paid comparisons require a separately authorized ceiling.

## Sources

The sentence and procedure guidance adapts ASD-STE100 Issue 9, rules 3.6,
5.1–5.4, and 6.3. Technical terminology is addressed in section 1.
See the [official standard](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)
and [official FAQ](https://www.asd-ste100.org/STE_faq.html). Authorization,
provider parity, and verification requirements above are repository rules.
