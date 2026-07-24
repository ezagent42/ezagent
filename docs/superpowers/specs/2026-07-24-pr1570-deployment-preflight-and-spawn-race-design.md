# PR #1570 deployment preflight and spawn-race design

## Goal

Make the Agent display-name uniqueness migration safe to promote and prove that
a failed fresh spawn cannot tear down a concurrently adopted spawn for the same
Agent URI.

## Deployment preflight

The Agent-only partial unique index remains the enforcement mechanism. The
migration will not mutate or silently deduplicate historical data.

Add a read-only Mix task that queries `entity_profiles` for Agent rows grouped
by `(workspace_uri, display_name)` with a count greater than one. It prints each
conflict deterministically and exits non-zero when any conflict exists. It exits
zero, with an explicit no-conflicts message, otherwise. Operators run it against
the exact canary, beta, or stable database snapshot before applying the
migration.

This preserves auditability: an unexpected duplicate is a deployment decision
and data-repair task, not an implicit application-side rename.

## Same-URI spawn race

Add an integration regression using the existing `TemplateSpawn` test hook:

1. Start the first fresh spawn and pause it immediately after its display
   profile is written.
2. Start a second spawn for the same URI and let it observe/adopt the existing
   worker (`fresh?: false`).
3. Release the first spawn into the injected post-profile failure.
4. Assert that the adopted spawn remains successful and that its worker,
   workspace binding, and active lineage fact remain present.

The production correction, if the test exposes the race, is ownership-aware
rollback: only the call that still owns the fresh worker may terminate or clean
its active products. Provenance stays append-only in every outcome.

## Non-goals

- No automatic data deduplication or historical-name rewrite.
- No relaxation of the append-only derivation-edge invariant.
- No change to User-profile uniqueness semantics.
