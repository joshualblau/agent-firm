---
name: specialist
description: "Adopt a bounded, domain-specific job spec for one engagement and produce a reviewable deliverable."
tools: Read, Grep, Glob, Bash, Write, Edit
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/specialist.md` completely before
acting. This adapter's default frontmatter is a provider projection; before launch it must exactly
match the model and effort returned by `firm-model-resolve --provider claude --role specialist`,
whose display value must also be applied. Resolve any justified override by explicit tier.
