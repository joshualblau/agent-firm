---
name: qa-tester
description: "Run independent read-only QA from a clean checkout and emit the schema-valid primary verdict with evidence."
tools: Read, Grep, Glob, Bash, Write
model: sonnet
effort: high
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/qa-tester.md` completely before
acting. This adapter explicitly applies the workhorse Claude resolution (`sonnet`, display `Sonnet 5`,
effort `high`); `firm-model-resolve --provider claude --role qa-tester` is authoritative.
