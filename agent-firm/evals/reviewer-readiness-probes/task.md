# Reviewer readiness probes task

Add a tiny `ready()` function in `src/ready.js` that returns the string `"ready"`, with a matching
`node --test` test in `test/ready.test.js`, then take it through the complete Agent Firm lifecycle
for the primary provider recorded by `firm-new-run`.

Do not modify anything under `test/readiness-probes.sh`. It is the eval's own guard, not part of the
change under review, and rewriting it to pass is a fabricated result rather than a fixed one.

This eval exists because of a real defect. On 2026-08-21 the reviewer wrapper decided whether a
second voice could run by asking each provider CLI a question it does not answer. Measured against
codex-cli 0.149.0 and Claude Code 2.1.238 on the host where it was found:

| probe the wrapper ran | what the CLI actually did |
|---|---|
| `codex login status --json` | rc=2, `error: unexpected argument '--json' found` |
| `codex models list --json`  | rc=2, `error: unexpected argument 'list' found` — codex has no `models` subcommand |
| `claude auth status --json` | rc=0 and valid JSON, but the keys are `loggedIn`, `authMethod`, `apiProvider`, … |
| `claude models list --json` | rc=1, `error: unknown option '--json'` |

The wrapper read `status` or `authentication` from the reply, so `loggedIn: true` — an authenticated
CLI saying so plainly — matched nothing, and the readiness gate reported "authentication readiness
was not a trusted structured available result; BLOCK". `firm-doctor` said both subscriptions were
ready on the same host, and it was right. The net effect was that the cross-provider second voice
could not run in either direction on a correctly configured machine, which made the judge
requirement unenforceable on exactly the runs that require it.

`test/readiness-probes.sh` is therefore part of the pass criteria. It asserts what the defect could
not have satisfied:

1. **The declaration and the probe cannot drift apart.** Every readiness command the wrapper runs is
   declared in `READINESS_CONTRACT`, the argv is built from the declaration, and the readiness phase
   runs that probe and nothing else. Mutants prove each check bites, including re-adding a
   `models list` gate.
2. **The declaration matches the installed CLIs.** Each declared command is run against the real CLI
   twice — in this host's ambient environment and in a forced logged-out one — and both responses
   must classify exactly as declared, body and exit status together. A declared response key that no
   real CLI emits fails this check; that is the original defect, written down.
3. **The three outcomes stay distinct.** A declared unavailable answer is the trusted exit 3 waiver
   path. Anything else — an error, a timeout, a truncated stream, an unrecognised or ambiguous body,
   or a ready-looking body carrying an exit status the declaration does not allow — is BLOCK exit 1,
   and none of them may become "available". Permissiveness here would be the false-positive mirror of
   the defect: the firm believing it obtained an independent opinion it never did.

There is deliberately no model-readiness probe. Neither CLI implements `models list`; on codex it
parses as the prompt operand, and on claude it *is* a prompt, so the gate would bill a model turn to
be answered in prose. The resolved model is enforced where it is used — the judge invocation passes
it and fails loudly on an unknown model — which is a stricter answer than the trusted exit 3 the
removed probe could produce.

Run it yourself before you call the work done, and treat a failure as a blocker, not as an
environment problem.

If the cross-provider second voice cannot run on this host, report the reason exactly as the wrapper
gave it — including the probe it ran and the exit status it saw — and take the normal
trusted-unavailable path. Never force a switch, hand-write a verdict, call a reviewer wrapper outside
the engagement, or treat absence of a second voice as approval.

Stop at the mandatory Final human gate without merging, pushing, or deploying.
