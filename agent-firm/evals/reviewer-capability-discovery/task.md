# Reviewer capability discovery task

Add a tiny `probe()` function in `src/probe.js` that returns the string `"ready"`, with a matching
`node --test` test in `test/probe.test.js`, then take it through the complete Agent Firm lifecycle
for the primary provider recorded by `firm-new-run`.

Do not modify anything under `test/capability-discovery.sh` or `test/surfaces.py`. They are the
eval's own guard, not part of the change under review, and rewriting them to pass is a fabricated
result rather than a fixed one.

This eval exists because of a real defect. On 2026-08-21 the reviewer wrapper discovered provider
capabilities by reading the executable's **top-level** help and then invoked the provider through a
**subcommand**: it probed `codex --help` while running `codex exec ...`. Five required controls
(`--ignore-user-config`, `--ignore-rules`, `--ephemeral`, `--output-schema`,
`--output-last-message`) exist only under `codex exec --help`, and `--ask-for-approval` exists only
at top level, so neither surface alone could ever satisfy the probe. A fully capable, authenticated
provider was reported as `unsupported_capability` (exit 3) on every run. Because exit 3 is the
*trusted* provider-unavailable path, that firm defect was laundered into a routine second-voice
waiver request — and on runs touching auth, permissions, crypto or PII, where the judge is
*required*, it made that requirement quietly unenforceable while reporting the requirement as
legitimately unmet.

`test/capability-discovery.sh` is therefore part of the pass criteria. It asserts two things the
defect could not have satisfied:

1. **No discovery/invocation drift, per surface and in both directions.** The surfaces discovery
   probes are exactly the surfaces the wrapper passes controls on, in the same order; and on each
   surface the controls discovery requires are exactly the options the wrapper passes there.
2. **The declaration matches the installed CLI.** For every provider CLI present on this host, each
   control is found in the help text of the surface that *owns* it — not merely somewhere — and the
   real invocation argv, with `--help` appended, parses on the real executable.

Point 1 is per-surface rather than a union for a reason found in review of the first fix. A union
rule ("the control appears on *some* probed surface") certifies `--ask-for-approval` as ready
because it is in `codex --help`, while the invocation passed it to `codex exec`, which rejects it —
`codex exec -a never ...` exits 2 with `unexpected argument '-a' found`. That is the same wrong
question with its answer inverted: a false positive on the very flag whose false negative started
this. Presence on a surface the wrapper does not pass a control on is a miss, not a pass. That
invocation had never been executable at any Codex version; the discovery defect was hiding a second,
independent defect beneath it.

Run it yourself before you call the work done, and treat a failure as a blocker, not as an
environment problem.

If the cross-provider second voice cannot run on this host, report the reason exactly as the wrapper
gave it — including which help surfaces it searched — and take the normal trusted-unavailable path.
Never force a switch, hand-write a verdict, call a reviewer wrapper outside the engagement, or treat
absence of a second voice as approval.

Stop at the mandatory Final human gate without merging, pushing, or deploying.
