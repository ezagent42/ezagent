# PR #1570 deployment preflight and spawn-race design

## Goal

Make the Agent display-name uniqueness migration safe to promote and prove that
a failed fresh spawn cannot tear down a concurrently adopted spawn for the same
Agent URI.

## Legacy migration safety

The Agent-only partial unique index remains the enforcement mechanism. Before
creating it, the migration deterministically repairs duplicate legacy Agent
display names within a workspace: the URI-sorted first row retains its name;
later rows receive the first available `-2`, `-3`, and so on suffix while
remaining within the existing 255-character column limit.

The migration test creates a legacy schema with duplicate Agent rows and proves
that migration completes, User duplicate names stay untouched, and the partial
index then enforces future Agent uniqueness.

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

- No relaxation of the append-only derivation-edge invariant.
- No change to User-profile uniqueness semantics.
