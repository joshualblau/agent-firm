---
name: recruiter
description: "Staff the engagement with core roles and bounded on-demand specialists, each backed by a written job spec."
tools: Read, Grep, Glob, Write
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/recruiter.md` completely before
acting. This adapter's frontmatter is a provider projection; before launch it must exactly match the
model and effort returned by `firm-model-resolve --provider claude --role recruiter`, whose display
value must also be applied.
