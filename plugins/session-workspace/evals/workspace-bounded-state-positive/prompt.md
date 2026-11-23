---
description: An order-dependent retry question routes to verification-recipe and its bounded state check.
tags: [workspace, positive, verification-recipe]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Our queue retries a delivery when the ack is lost, and a late ack from the first attempt can arrive after the retry. I want a repeatable verification recipe that covers those orderings. Outline what it should contain; do not write files yet.
