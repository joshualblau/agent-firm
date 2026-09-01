# Final primary evidence seal golden task

Add a tiny `src/value.txt` file and take it through a full Agent Firm run. After primary QA has
written its final verdict and traceability, prepare the non-ship-ready draft handoff with the complete
local PR body between the canonical markers and run `firm-seal-qa-evidence --run <exact-run-dir>`.
Then invoke the opposite-provider wrapper and stop at the mandatory Final human gate.

The retained evidence must prove the seal and reviewer independently agree on exact handoff/PR bytes,
ordinary paths and counts (including the separate self entry), privacy policy and final-byte scans,
the target-ledger prefix, typed publication, and reviewer suffix. Reproduce and require BLOCK for
each BLOC-51 mutation: handoff or verdict changed after privacy; two PR extractors disagree; the seal
self entry is omitted while claiming `41 == 40`; traceability has no unique current producer;
command evidence contains placeholder argv or missing cwd; a referenced artifact is omitted; and an
unexpected ledger append occurs. Both primary orientations must supply the same sealed set to their
opposite provider. Do not repair or fall back to v3 after any protocol-v1 state exists.

No merge, push, deploy, plugin reinstall, cache refresh, credential mutation, or external action.
