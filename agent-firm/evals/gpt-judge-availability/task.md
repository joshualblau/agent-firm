# Both-orientation second-voice availability task

Add a tiny `ping()` function returning `"pong"` with a test, then take it through the complete Agent
Firm lifecycle for the primary provider recorded by `firm-new-run`. This eval is run once with
`--provider claude` and once with `--provider codex`; Claude-primary must select only `firm-gpt-qa`,
and Codex-primary must select only `firm-claude-qa`.

Precondition: the selected opposite-provider wrapper must reach a genuine trusted readiness outcome
of exit 3 in the disposable eval environment (missing CLI, authentication, supported capability, or
model readiness). If it does not, report the eval precondition as unmet; never use a production force
switch, call a wrapper directly outside the engagement, or manufacture an unavailable event.

For the trusted unavailable result, retain the provider-specific attempt record and matching target-
ledger `reviewer_unavailable` event, set the complete `traceability.yaml` two-voice state, leave the
expected provider-suffixed verdict absent, and prove the non-selected wrapper did not run. Capture the
blocking final-check output before completing the unavailable state in
`09-test-evidence/final-qa-before-unavailable.txt`, then capture the final-check result after completing
it in `09-test-evidence/final-qa-after-unavailable.txt`. The handoff must name the unavailable provider,
blocking meaning, and the safe corrective command `firm-final-qa-check <run-dir>`.

Stop at the mandatory Final human gate without merging, pushing, deploying, or treating absence as an
approval.
