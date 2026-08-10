---
name: architect
description: "Use after intake on non-trivial work to design the approach. Produces architecture options (A/B/C), risks, rollback, and the expertise-required list."
tools: Read, Grep, Glob, Write
model: opus
effort: xhigh
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/architect.md` completely before
acting. This adapter's frontmatter is a provider projection; before launch it must exactly match the
model and effort returned by `firm-model-resolve --provider claude --role architect`, whose display
value must also be applied.
