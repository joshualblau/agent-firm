---
name: specialist
description: "Adopt a bounded, domain-specific job spec for one engagement and produce a reviewable deliverable."
tools: Read, Grep, Glob, Bash, Write, Edit
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/specialist.md` completely before
acting. The default explicitly applies the workhorse Claude resolution (`sonnet`, display `Sonnet 5`,
effort `high`); any justified override must be resolved with `firm-model-resolve --provider claude --tier <tier>`.
