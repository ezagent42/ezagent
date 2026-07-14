# Hello live E2E and Kanban fusion design

## Goal

Deliver the demo product path from the public website into hello, prove hello's
real live generation loop, and let a user delegate work to Kanban from the hello
conversation. The Kanban connection is deliberately loose-coupled for this
increment: hello copies a task into a workspace Kanban board; it does not claim
to implement the cross-session live mount described by #1360 Layer B.

The work continues #1312's visible-control, sharer/publisher, v2 seed-page, and
rebuild-guide foundation. It also closes the product-facing proof gap recorded
in the 2026-07-13 review: the agent reply path is now available, so hello can be
chain-tested through Kanban instead of stopping at backend seams.

## Product journey

1. A visitor reaches the website, signs in when an operation requires identity,
   and enters a hello conversation.
2. The hello greeter accepts a real prompt. The session's curl-LLM agent uses
   DeepSeek to produce a json-render specification.
3. `EzagentPluginHello.Spec.validate/1` accepts only catalog-valid output, and
   the live hello surface renders it.
4. A second prompt changes the existing page through the PATCH path rather than
   silently replacing the product flow with a stub.
5. The concierge answers questions from the current page and remains read-only:
   it changes neither the Surface nor Kanban.
6. An anonymous visitor can see the public hello view. Anonymous write-like
   requests are login-gated.
7. An authenticated user says, in the hello conversation, "hand this to
   Kanban" (or equivalent wording). Hello creates a task in the workspace's
   default Kanban and replies with a confirmation and link.

The primary Kanban entry is conversational. This increment does not add a page
CTA as a second source of truth.

## Architecture

### Hello-owned dispatcher role

Add a hello-native `dispatcher` role whose single responsibility is converting
hello context into a Kanban task. A new agent type or Kind is forbidden; this is
a role on the existing unified Agent primitive.

The hello Router intent set becomes:

```text
builder | concierge | sharer | publisher | dispatcher
```

The routing prompt gains a `KANBAN` result. A classified Kanban request is
dispatched to the hello dispatcher through the normal Invocation path. It must
not be routed through the concierge: #1134's concierge/public-read boundary
remains structurally read-only.

If intent classification fails, the existing owner default remains `builder`.
Failure must never create a Kanban task accidentally.

### Loose-coupled Kanban handoff

The dispatcher uses public platform contracts rather than reading or mutating
Kanban slices directly:

1. derive the current workspace from the hello session;
2. resolve the workspace's explicitly designated default Kanban;
3. if none exists, create a `kanban-manager` role on the `native` flavor through
   the sanctioned workspace agent-creation path;
4. dispatch `kanban.add_node` to create the task;
5. post the result back into the hello conversation as the dispatcher.

If several Kanbans exist, selection must use an explicit default marker or a
single canonical resolver. List order is not a valid selection rule. The
resolver is the one source of truth shared by the product flow and tests.

The created task contains:

- title: the user's current delegation instruction;
- source hello session URI;
- public or operator-visible hello URL as appropriate;
- a summary of the current hello page when one exists;
- the original user text for traceability.

Missing page content does not block delegation. In that case the task carries
the instruction and session link only.

The success reply includes the task title, node identifier, and a clickable
World Kanban URL. Any create/dispatch failure produces an explicit chat error;
the UI must not claim success before the node exists.

## Authentication and anonymous continuation

An anonymous visitor may read and ask concierge questions on a public hello
session, but may not create Kanban work.

When an anonymous visitor asks to delegate:

1. no Kanban mutation occurs;
2. the application stores the minimum pending action needed to continue: hello
   session, instruction, and an idempotency identifier;
3. the visitor is sent through the existing login path;
4. after successful login, the pending action is consumed once and delegated
   under the authenticated principal;
5. refresh, back navigation, or repeated login cannot create a duplicate node.

The continuation must use an existing authenticated session/pending-action seam
where possible. It must not introduce a second authentication mechanism or
trust caller identity supplied by the browser.

## Surface ownership and World coordination

This effort owns:

- the hello Router, routing prompt, dispatcher role/behavior, hello task
  context, and hello-side product evidence;
- additive login-continuation integration required for the hello action;
- tests and evidence specific to the hello-to-Kanban journey.

Existing Kanban rendering remains owned by the registered World Kanban plugin
page. World remains transport and does not gain a parallel Kanban implementation.

The World coordination rules are:

- no `styles.css` edits in this effort;
- prefer hello's own island CSS or existing component classes for any new copy;
- any World change is additive and must use the registered typed-slot/plugin
  page architecture;
- do not import World's bundle into hello; reuse contracts and transport
  patterns, not frontend bundles;
- record any shared file touched and serialize it with the active World owner.

The surface declaration is therefore:

```text
hello entry + delegation UX: ezagent_plugin_hello
Kanban operation/rendering: ezagent_plugin_kanban + existing World plugin page
login/session continuation: ezagent_web, additive seam only
```

## Failure behavior

- Intent classification failure falls back to builder and performs no Kanban
  mutation.
- Default-Kanban resolution fails loud on ambiguous state; it never guesses by
  ordering.
- Kanban creation or `add_node` denial/failure is surfaced in hello chat.
- Pending delegation is single-use and idempotent.
- Missing page summary degrades to instruction plus source link.
- Concierge answers remain read-only by construction and regression test.
- Anonymous users cannot obtain Kanban write authority from a public-view cap.

## Verification and Definition of Done

### Hello live E2E proof

The live proof uses the real product surface and a real curl-LLM/DeepSeek path,
not a stub. Evidence must demonstrate:

1. greeter entry accepts a real prompt;
2. DeepSeek returns a json-render spec through the curl-LLM agent;
3. `Spec.validate/1` accepts the landed spec;
4. the live page renders through the hello catalog;
5. a second prompt uses the edit/PATCH path and visibly changes the page;
6. concierge answers from current page content without changing the page;
7. anonymous `public_view` renders successfully;
8. the live catalog remains constrained to the shipped 36-component contract.

The historical "6-point" label is retained for the journey, but the proof is a
closed eight-line checklist so anonymous visibility and the catalog constraint
cannot disappear inside a combined assertion.

### Hello-to-Kanban product proof

Evidence must demonstrate:

1. an authenticated user delegates from hello chat;
2. the default Kanban resolves, or is created when absent;
3. exactly one real Kanban node is created with the agreed source context;
4. hello replies with a working Kanban link;
5. the existing World Kanban surface displays the node;
6. an anonymous delegation request crosses login and resumes once;
7. repeating the continuation does not duplicate the node;
8. concierge Q&A creates no Surface or Kanban writes.

### Automated and human-readable evidence

- LiveView tests mount the real routes and assert outcomes through stable DOM
  IDs, including login continuation and the World Kanban result.
- Domain/integration tests cover Router classification, dispatcher authorization,
  default-board resolution, task payload, error surfacing, and idempotency.
- Agent-browser drives login -> hello generation -> PATCH -> concierge ->
  anonymous view -> Kanban delegation -> World Kanban display.
- Store screenshots as a companion to, not a replacement for, the automated
  proof.
- Store the real-channel transcript with backend/model identity and timestamps
  sufficient to show DeepSeek was used.
- Align the hello-side delegation payload with jjkysy's Kanban/mount work and
  document the contract boundary; do not claim Layer B mount completion.

### Return gate

Before return:

- run targeted regression tests and frontend build/type checks;
- run the complete static gate set: `arch.scan`, `doc.scan`, `uri_query.scan`,
  `check_invariants`, format checks, and plugin checks;
- run `mix precommit` and the relevant full regression suite;
- rebase the task branch on current `main`;
- require PR-head CI green;
- attach the agent-browser screenshots and real transcript to the return/PR.

## Explicit non-goals

- Implementing #1360 Layer B cross-session live mounting.
- Adding a page CTA as a second delegation entry.
- Letting concierge mutate the page or Kanban.
- Building a second Kanban UI inside hello.
- Editing shared World `styles.css`.
- Replacing the existing authentication or Kanban dispatch contracts.
