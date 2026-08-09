---
name: architect
description: "Use after intake on non-trivial work to design the approach. Produces architecture options (A/B/C), risks, rollback, and the expertise-required list."
tools: Read, Grep, Glob, Write
model: opus
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/architect.md` completely before
acting. That shared contract is authoritative; this file only selects the Claude model and tools.
