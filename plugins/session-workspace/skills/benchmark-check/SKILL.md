---
name: benchmark-check
description: Check a performance claim with comparable inputs, correctness and work-count checks, repeated interleaved samples, and the end-to-end limiter, reporting inconclusive when the evidence cannot decide. Use before claiming a change is faster, slower, or cheaper, or when reviewing such a claim.
---

# Benchmark check

Decide whether a measured difference is real and matters. This is measurement
guidance, not a benchmark framework, and it grants no new execution authority.

## Define the claim first

State the claim, the metric (latency, throughput, memory, cost), the baseline
and candidate subjects (exact revisions plus dirty-state identity), the input
set, and the smallest difference that would matter. Fix the decision threshold
before running, not after seeing results.

## Make samples comparable

- Use the same inputs, build flags, configuration, machine, and runtime for
  baseline and candidate. Record platform, versions, and relevant load.
- Check correctness on every sample: outputs or observable state must match, and
  work counts (items processed, bytes, queries, calls, iterations) must be equal
  or explained. A faster run that did less work is not an improvement.
- State cache and warm-up policy. Discard warm-up runs consistently for both.
- Interleave baseline and candidate (A B A B …, or randomized order) so drift,
  thermal state, and background load affect both alike. Never run all of one
  subject and then all of the other.
- Repeat enough to see the spread. Report median and spread (interquartile
  range or min–max) and the raw samples, not a single best run.

## Find the limiter

Identify what bounds the user-visible path (CPU, I/O, network, lock contention,
external service, human wait) with a profile or a targeted measurement. A gain
in a component that is not the limiter is reported as a micro-result, not an
end-to-end improvement. Measure the end-to-end path the claim is about as well
as any micro-benchmark.

## Report the outcome

Report exactly one of: **improved**, **regressed**, **no detectable change**, or
**inconclusive**. Use no detectable change when comparable, sufficiently repeated
samples show no difference above the predefined decision threshold. Use
inconclusive when noise prevents that judgment, correctness or work counts
disagree, inputs were not comparable, samples are too few, or the run was
interrupted. Never relabel inconclusive as improved.
Include commands, sample counts, raw data location, source identity, and
omissions. Changed source or configuration invalidates the result.

## Boundaries

Run only within the caller's existing role and authorization, with isolated data
and a bounded duration. Do not use live stores or production services, do not
load shared machines or external services without permission, and do not change
product behavior to improve a measurement. Keep raw results local and inspect
them before sharing.
