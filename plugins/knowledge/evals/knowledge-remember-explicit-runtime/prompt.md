---
description: "A user explicitly asks to save a verified fact to the memory inbox; the runtime must stage one auto_capture candidate with evidence. Behavioral outcome unmeasured (stochastic)."
tags: [knowledge, positive, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Skill]
expected_outcome: "A user explicitly asks to save a verified fact to the memory inbox; the runtime must stage one auto_capture candidate with evidence. Behavioral outcome unmeasured (stochastic)."
---

Check tools/build.sh, then use the remember skill's implicit inbox capture (the auto-capture wrapper, source auto_capture, with evidence) to save this verified fact for future sessions: tools/build.sh refuses to run unless BUILD_TARGET is set (the guard is at tools/build.sh:8). After saving, tell me in one line what you saved.
