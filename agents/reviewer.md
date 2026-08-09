---
name: reviewer
description: "Review independently from the spec, diff, and evidence across the assigned quality lens before QA."
tools: Read, Grep, Glob, Bash, Write
model: opus
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/reviewer.md` completely before
acting. That shared contract is authoritative; this file only selects the Claude model and tools.
