# Hello Session Retry Completeness Design

## Problem

`EzagentPluginHello.App.create_app/3` currently treats an existing Session with
the requested owner as a completed idempotent create. The owner is written when
the Session Kind is spawned, before workspace binding, owner capabilities,
frozen template declarations, installs, and template configuration. A failure
after the spawn can therefore leave a same-owner half-created Session that a
retry incorrectly reports as successful.

The concurrent session-create regression test has a separate false-positive:
its `for` comprehension only visits successful result tuples. If every create
returns an error, the assertion body runs zero times and the test passes.

## Chosen Design

### Repair a same-owner Hello Session by replay

Keep the existing owner conflict rule: a Session owned by another entity returns
`:derivation_edge_conflict`.

For a Session already owned by the requested owner, call the same
`create_fresh_app/4` pipeline used by a fresh create instead of returning
immediately. The pipeline's operations are intentionally idempotent:

- reuse the immutable parent-template derivation and exact frozen revision;
- accept an already-live Session Kind;
- rebind the Session to its workspace;
- regrant deduplicated owner capabilities;
- reinstall the frozen template records;
- rewrite the durable member declarations and template configuration.

This repairs missing post-spawn state without terminating an otherwise usable
Session. Agent roles remain outside the create transaction and continue to be
materialized by the existing post-create socialware-install transaction.

### Make the concurrent-create test fail closed

Require the async stream to return exactly three result tuples and assert that
each tuple contains a successful Session create before checking latency, URI,
and durable snapshot. Errors and task exits must fail the test rather than being
filtered out.

## Tests

1. Create a Hello Session, remove post-spawn state to model a partial create,
   retry `App.create_app/3`, and assert that the original frozen template is
   retained while workspace binding and template declarations are restored.
2. Add a small result-validation seam for the concurrent-create test and prove
   that an error result is rejected, preventing a vacuous pass.
3. Run the focused Hello retry, credential-admission, freeze-pin, and
   session-create tests.
4. Run `mix precommit` as the final project gate.

## Non-goals

- Do not wait for `front-desk` or `llm` materialization inside session creation.
- Do not terminate and recreate an existing same-owner Session.
- Do not change cross-owner conflict behavior.
- Do not alter credential-admission state transitions.
