---
name: reviewer
description: "Review independently from the spec, diff, and evidence across the assigned quality lens before QA."
tools: Read, Grep, Glob, Bash, Write
model: opus
effort: xhigh
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/reviewer.md` completely before
acting. This adapter's frontmatter is a provider projection; before launch it must exactly match the
model and effort returned by `firm-model-resolve --provider claude --role reviewer`, whose display
value must also be applied.
