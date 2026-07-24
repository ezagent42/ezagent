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

The complete `TemplateSpawn.spawn_from_template_content/5` chain is serialized
per canonical `instance_uri` using the existing
`Ezagent.Lifecycle.with_entity_transition/2` URI transition lock. The critical
section starts before credential-grant resolution and ends only after spawn
success or compensation has completed. It therefore covers every resource
whose identity is the Agent URI: credential grant, worker, profile, workspace
binding, active lineage, runtime flavor/config, and creation inventory.

The winner either succeeds or finishes compensating the active products it
created before the next caller can act. Provenance remains append-only and is
not compensation state.

When a queued second request obtains the lock:

- if the first request succeeded, it returns `:agent_uri_already_live` with
  zero mutation of the winner's resources;
- if the first request failed, it runs a normal fresh creation after the
  failed attempt's cleanup has completed.

The existing `fresh?: false` adoption branch becomes strictly read-only for
this entry point: it must not update sandbox state or flavor attributes and
must not revoke a grant keyed by the existing URI.

Integration coverage uses the existing post-display-profile hook to hold the
first request while a second request queues on the same URI:

1. A succeeds and B returns `:agent_uri_already_live`; assert all of A's
   worker, profile, workspace-binding, active-lineage, flavor, config and
   grant state survives unchanged.
2. A is released into an injected failure; B then creates successfully; assert
   no active product from A remains while its append-only provenance remains.

## Non-goals

- No relaxation of the append-only derivation-edge invariant.
- No change to User-profile uniqueness semantics.
- No new Core synchronization primitive or database reservation table.
