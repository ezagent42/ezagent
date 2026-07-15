# Hello live E2E completion and Kanban fusion deepening

## Goal

Continue the merged #1383 product path on the existing
`feat/hello-recording-ready` branch. Complete the real DeepSeek-backed Hello
live E2E proof and deepen Hello-to-Kanban integration without making Hello a
second board owner. #1360 Layer B remains out of scope.

The replacement PR will contain the existing recording-ready website entry,
the completed live proof, the strengthened delegation contract, and the final
adapter to Kanban's sharing/permission capability once that capability lands on
`main`.

## Product contract

Kanban plugin remains the sole owner of task state, sharing configuration, and
authorization. Hello owns the public product entry, the authenticated
delegation intent, and presentation of a permission-aware Kanban reference.

Hello stores only stable references needed to locate the delegated task:

- `board_uri`;
- `node_id`;
- source `session_uri`;
- the canonical World/open URL returned by the Kanban contract.

Hello must not persist a mirrored task record, reproduce Kanban's permission
rules, read Kanban state slices directly, or treat a creation-time receipt as a
live read model.

## Delegation and shared-read adapter

The existing dispatcher remains the single Hello mutation path. It delegates
through sanctioned Invocation/Plugin contracts and returns a stable task
reference only after a real node exists.

The read side is a replaceable adapter with these conceptual outcomes:

```text
fetch_shared_task(caller, board_uri, node_id)
  -> {:ok, shared_task}
  -> {:error, :forbidden}
  -> {:error, :not_shared}
  -> {:error, :not_found}
  -> {:error, :unavailable}
```

`shared_task` is a bounded presentation value supplied by Kanban. The initial
UI consumes title and status; assignee, phase, and artifacts may be shown only
when the Kanban sharing contract explicitly exposes them.

Until the colleague-owned Kanban sharing implementation lands, Hello may define
and test the adapter boundary but must not ship a duplicate fallback permission
model. After it lands, rebase on `origin/main`, adopt its real interface, and
delete any obsolete assumptions in the adapter.

## Refresh behavior

The preferred implementation consumes a Kanban-owned subscription or change
notification if one is provided. If the landed contract is read-only, the
first increment refreshes on page entry and at a bounded interval while the
receipt is visible.

Every refresh re-authorizes through Kanban. Cached success never grants future
access. The UI behavior is closed:

- allowed: render the latest shared fields;
- forbidden: replace details with an explicit permission-limited state;
- no longer shared: explain that the task is no longer shared;
- deleted: render a stable unavailable/deleted state;
- temporary failure: keep the reference link and show a retryable status, not
  stale data presented as current.

Hello never writes back merely because it refreshed. Any future Hello-side edit
must dispatch through a separate Kanban-authorized mutation contract and is not
part of this increment.

## Real DeepSeek live E2E

The live proof must use the session's real curl-LLM member and DeepSeek, not a
stub. It records a transcript and agent-browser screenshots that establish:

1. a greeter prompt reaches the real DeepSeek model;
2. DeepSeek returns a json-render specification;
3. `EzagentPluginHello.Spec.validate/1` accepts the specification;
4. the live renderer displays the page;
5. a second prompt changes the existing page through PATCH/edit semantics;
6. concierge answers from the current page without mutating it;
7. an anonymous visitor can read the public view;
8. the rendered spec remains inside the shipped 36-component catalog.

The transcript records timestamps, provider/model identity, validation result,
surface revision before/after PATCH, concierge read-only evidence, anonymous
route result, and catalog component count. It never prints credentials.

If the configured DeepSeek credential is rejected or the host cannot reach the
provider, the work is not complete. Deterministic tests may use fakes for error
branches, but their output cannot be presented as live evidence.

## Surface ownership and World coordination

This effort owns:

- Hello product entry, prompt/delegation UI, receipt rendering, and refresh
  behavior;
- Hello-side adapter and tests for the Kanban sharing contract;
- Hello live E2E evidence and transcript.

Kanban owns task data, sharing, permission decisions, and the World Kanban
product surface. This effort does not edit `apps/ezagent_plugin_world/assets/src/styles.css`.
Any World touch must be additive, follow the typed-slot/layout gates, and be
coordinated under `docs/guide/world-coordination.md`.

Surface declaration:

```text
Hello entry and receipt UX: ezagent_plugin_hello / socialware viewer
task state, sharing, authorization: ezagent_plugin_kanban
operator board presentation: existing World Kanban plugin surface
login continuation: ezagent_web additive seam
```

## Verification

Automated coverage must prove:

- delegation returns a real stable board/node reference;
- the Hello read adapter uses the Kanban contract and caller identity;
- allowed updates change the Hello receipt after a Kanban edit;
- revoked or absent sharing removes details without leaking stale fields;
- deletion and temporary failure have explicit UI states;
- anonymous users never receive write authority;
- concierge creates no Surface or Kanban mutation;
- login continuation remains single-use and idempotent;
- the real routes render through stable DOM IDs;
- the 36-component catalog constraint remains live.

Product evidence must drive the real route through login, Hello generation,
validation, render, PATCH, concierge, anonymous view, delegation, Kanban edit,
and refreshed Hello receipt. Screenshots accompany the transcript and include
the matching World task.

Before the replacement PR is opened:

- run targeted Hello, socialware, web, Kanban, and World regression tests;
- run frontend contract/build checks;
- run the full static gate set and `mix precommit`;
- rebase on current `origin/main`;
- require PR-head CI green;
- attach screenshots, transcript, and recording companion.

## Non-goals

- #1360 Layer B mounting;
- a second Kanban datastore or copied permission system in Hello;
- unrestricted anonymous task reads;
- Hello-side task editing;
- a new World route or World `styles.css` change;
- claiming fake/model-stub output as live DeepSeek evidence.
