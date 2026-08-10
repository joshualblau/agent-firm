---
name: scout
description: "Perform cheap, broad, read-only reconnaissance and return a compact repository map."
tools: Read, Grep, Glob
model: haiku
effort: low
---

Use Read to load `${CLAUDE_PLUGIN_ROOT}/agent-firm/contracts/roles/scout.md` completely before acting.
That shared contract is authoritative. This adapter's frontmatter is a provider projection; before
launch it must exactly match the model and effort returned by `firm-model-resolve --provider claude
--role scout`, whose display value must also be applied.
