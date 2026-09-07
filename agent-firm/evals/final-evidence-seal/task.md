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

Then execute the complete closed AC-007 preflight mutation matrix and publish its evidence. Every
required family must be run as a real fail-closed case — opted-in and partial no-fallback state,
both-provider sealed fixtures, privacy category and surface misuse, placeholder argv, unexpected
ledger appends, producer-window defects, duplicate and malformed integration-history indexes, the
complete malformed complete-PR marker family, seal tamper, evidence tamper, synchronized TOCTOU, and
the one genuine-legacy run that keeps its previously approved reviewability. For each family record
the exact fail-closed category it observed, that no seal and no reusable partial generation were
produced, that the tested ledger prefix stayed byte-identical, and that the provider-call count did
not change. Write one immutable canonical document per family under
`09-test-evidence/mutation-evidence/`, index them in the schema-versioned closed manifest
`09-test-evidence/mutation-evidence/ac007-manifest.json`, and publish each of them — the manifest
included — with its own `evidence_produced` event bound to the current candidate, generation, exact
byte count and lowercase SHA-256. A prose claim that the matrix ran, or an aggregate count of
passing cases, is not evidence and will not satisfy the golden assertion.

No merge, push, deploy, plugin reinstall, cache refresh, credential mutation, or external action.
