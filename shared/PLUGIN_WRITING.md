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
4. Record coverage and exceptions. Do not claim full STE conformity or measured model improvement from an editorial review.

Keep this authoring guide in the repository. Shipped skills must remain usable
without reading it. Avoid repeating this entire guide in each skill.

## Sources

The sentence and procedure guidance adapts ASD-STE100 Issue 9, rules 3.6,
5.1–5.4, and 6.3. Technical terminology is addressed in section 1.
See the [official standard](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf)
and [official FAQ](https://www.asd-ste100.org/STE_faq.html). Authorization,
provider parity, and verification requirements above are repository rules.
