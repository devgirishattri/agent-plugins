---
description: "Ordinary-language how/why question about seeded code; the explain skill should fire, cite the recorded weekend reason, and label the unrecorded retry rationale."
tags: [knowledge, positive, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Skill]
expected_outcome: "Claude uses explain, cites tools/notify.sh, gives the recorded weekend reason, labels the retry rationale inferred or unknown, and writes nothing."
---

How does tools/notify.sh decide whether to send a notification, and why does it retry three times and skip weekends? Keep it short.
