---
name: recruiter
description: "Staff the engagement with core roles and bounded on-demand specialists, each backed by a written job spec."
tools: Read, Grep, Glob, Write
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/recruiter.md` completely before
acting. This adapter explicitly applies the workhorse Claude resolution (`sonnet`, display `Sonnet 5`,
effort `high`); `firm-model-resolve --provider claude --role recruiter` is authoritative.
