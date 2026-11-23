---
description: A consequential choice before review stated in ordinary language should produce a review note that carries the concrete choice, its reason, the evidence and the observed result; the note is shown, not submitted.
tags: [scheduler, positive]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

I'm the executor on task t7. The reviewer rejected my first fix, which retried the upload, because a retry can double-post. I made the upload idempotent instead, and tests/run.sh passes at commit abc1234. Write the review note I should submit for t7 and show it to me before you send anything.
