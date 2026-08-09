---
name: qa-tester
description: "Run independent read-only QA from a clean checkout and emit the schema-valid primary verdict with evidence."
tools: Read, Grep, Glob, Bash, Write
model: sonnet
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/qa-tester.md` completely before
acting. That shared contract is authoritative; this file only selects the Claude model and tools.
