---
name: behavioral-eval
description: Design and assess realistic behavioral evaluations of agent skills and workflow changes. Use when comparing a proposed instruction change or checking whether agents actually follow a workflow.
---

# Behavioral evaluation

Define the behavior that must improve, then test observable actions and artifacts.
Keep the current implementation as a baseline. Use the project's existing eval
runner rather than introduce another service or scoring system.

1. Write a realistic user request and controlled fixture. Keep grading criteria
   separate from candidate-visible prompts and files. Use neutral workspace names;
   do not tell candidates which variant they receive or which answer is expected.
2. Define positive and negative controls. Include the valid path and a plausible
   failure (missing evidence, stale subject, prohibited action, or unavailable
   dependency). A grader that accepts both is not useful.
3. Grade completed tool events with actual exit status and resulting artifacts.
   Candidate statements, mentioning a tool name, and reading an instruction file
   do not prove correct execution. Label missing traces or unsupported event
   formats as inconclusive. Keep deterministic assertions separate from model
   judgments; neither replaces the repository's mandatory runtime gates.
4. Run model-based comparisons only when the user explicitly authorizes model
   spend with a ceiling. Use isolated fixtures, configured runtimes, and bounded
   time/case counts. Never read unrelated conversations or use production stores.
   Without spending authority, validate fixtures and graders deterministically
   and report that behavioral effectiveness remains unmeasured.
5. Compare the same task set and environments across variants; record source,
   model/runtime versions, settings, run count, failures, incomplete runs and cost
   when available. Blind any independent judgment to model/variant names. Report
   disagreements and uncertainty rather than hiding failed or timed-out cases.

Promote an instruction change only with evidence relevant to its intended effect.
Do not train the grader to prefer the proposed wording or broaden permissions to
make a scenario pass. An evaluation report grants no release approval.

In the agent-plugins source checkout, `scripts/plugin-evals.py` validates portable
scenarios without model calls by default. Its `expectations.executions` assertions
count direct literal Bash script calls in completed command events with the
specified exit code and count bounds. A script must match an absolute installed
helper path and the runner's pre-run whole-plugin content digest, checked again
after the probe. Optional `args` or `args_prefix` binds the expected invocation.
One literal runtime shell
wrapper is supported; candidate-workspace lookalikes cannot satisfy a receipt. `expectations.json_contains` checks the
actual JSON artifact for expected fields. Legacy prose and tool-name grades are
retained for compatibility but do not establish execution. Composed commands are
intentionally not counted as direct receipts. The runner is source-checkout
tooling, not an installed helper or a security monitor.

The `executions` and `json_contains` fields are enforced only by that root probe
runner. Claude-native `case.yaml` graders do not assert these additional fields.

Execution observations are report-only provider events, not authenticated proof.
Pre/post hashing detects persistent changes, including imported helpers, but cannot
detect modify/run/restore or shell startup files, aliases, or functions that shadow
the requested program. A matching event does not establish that program execution
occurred in an uncompromised environment. Use deterministic gates for admission.
