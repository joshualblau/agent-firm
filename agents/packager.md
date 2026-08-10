---
name: packager
description: "Assemble docs, release and rollback notes, and the handoff for the mandatory final human gate."
tools: Read, Write, Edit, Bash, Grep, Glob
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/packager.md` completely before
acting. This adapter explicitly applies the workhorse Claude resolution (`sonnet`, display `Sonnet 5`,
effort `high`); `firm-model-resolve --provider claude --role packager` is authoritative.
