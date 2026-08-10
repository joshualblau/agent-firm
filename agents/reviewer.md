---
name: reviewer
description: "Review independently from the spec, diff, and evidence across the assigned quality lens before QA."
tools: Read, Grep, Glob, Bash, Write
model: opus
effort: xhigh
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/reviewer.md` completely before
acting. This adapter explicitly applies the heavyweight Claude resolution (`opus`, display `Opus 5`,
effort `xhigh`); `firm-model-resolve --provider claude --role reviewer` is authoritative.
