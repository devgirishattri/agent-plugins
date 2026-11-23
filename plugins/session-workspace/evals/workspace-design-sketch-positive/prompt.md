---
description: Choosing between competing interface designs routes to design-sketch without any workspace config.
tags: [workspace, positive, design-sketch]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
---

Other tools need to ask which team owns a file path. I can't decide between a new `owners` CLI subcommand, a JSON file they read directly, or an environment variable. tools/route.sh is the only caller today. Sketch the design before we plan anything.
