# 02 · Architecture options
<!-- Full-track only. Fast-path: write one line ("trivial; no design fork") and skip. -->

## Option A — minimal patch
- Approach:
- Risks:
- Files likely touched:

## Option B — clean refactor
- Approach:
- Risks:
- Files likely touched:

## Option C — strategic redesign
- Approach:
- Risks:
- Files likely touched:

## Recommendation
- **Chosen:** A | B | C
- **Why:**
- **Why not the others:**
- **Migration / rollback:**
- **Expertise required (→ Recruiter):**

## Plan of record
<!-- The chosen approach as a dependency-ordered task list. This is what the Lead executes. -->
| work-order | does | serves AC | depends on | parallel-safe? | risk |
|---|---|---|---|---|---|
| wo1 | | AC-001 | — | yes | low |

- **Integrator must own** (shared state / migrations / ports / fixtures):
- **Sequential-only** (same-file or ordered):
- **Needs a Fable 5 deep pass?** yes/no — why:
