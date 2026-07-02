# Agent Console Session Lifecycle

> Workstream: B - Session Delete / Archive Lifecycle Spec
> Date: 2026-07-02
> Branch: `worktree-agent-console-session-lifecycle-0702`
> Base: `adf5fad5`
> Status: spec-only return; no product code changed

## Recommendation

Do not ship a "Delete session" button as the first Agent Console slice.

The first product operation should be **Archive / End session**:

- stop new participation and operator mutations;
- remove anonymous/public web access;
- stop outbound mirrors and external feed delivery;
- stop the orchestrator executor and spawned workers that are owned by the session;
- preserve message history, audit rows, the session URI, the template/working-copy record, and enough member metadata for later inspection.

Permanent delete should remain a separate, narrower admin/retention operation after the archive model lands. The codebase already has a permanent-destroy cascade hook for live sessions, but it is not yet the right user-facing product semantic for Agent Console.

## Current Code Anchor

The existing system already contains a permanent destroy path:

- `Ezagent.Behavior.Session.destroy/2` delegates to `Ezagent.Behavior.Session.Teardown.cascade_teardown/2`.
- `cascade_teardown/2` best-effort reaps spawned participants, reaps the orchestrator agent, prunes session-created routing rows, and stops the per-orchestrator `Ezagent.Session.SessionManager`.
- `apps/ezagent_domain_session/test/integration/spawned_participant_teardown_test.exs` covers `Lifecycle.destroy(session)` tearing down spawned workers, config dirs, routing, and lineage.
- World UI already exposes participant removal through `Ezagent.Session.Participants.remove_participant/3`, sharing the CLI/domain path.

That is useful infrastructure, but it is a **destructive process teardown**, not a complete product lifecycle model. It does not yet define what remains visible, what happens to socialware/public links, external mirror bindings, message history, audit/provenance, or ConfigStore-backed install/working-copy state.

## Product Semantics

Use multiple operations, not one overloaded verb:

| Operation | Product meaning | First-slice status |
| --- | --- | --- |
| End session | Stop live execution, keep the record inspectable. | Merge with Archive for v1 wording. |
| Archive session | Hide from active lists and disable live/external entry points, while preserving history. | Recommended first slice. |
| Delete session | Permanently remove runtime state and possibly persisted records under a retention policy. | Defer. |

Suggested v1 UI label: **Archive session**.

Reasoning: users expect "delete" to remove data. The safer operator need is usually "this session is no longer active." Archive matches the current system better because sessions are durable referents: messages, audit rows, external bindings, public links, and template lineage can all point at the session URI.

## Archive Behavior

An archived session should remain addressable by URI and visible in an "Archived" filter/detail view, but should be non-live:

- active session lists exclude archived sessions by default;
- detail view is read-only and shows lifecycle status, archived timestamp, operator, and reason;
- chat/message history remains visible to authorized operators;
- routing mutations, participant add/remove, chat send, file upload, orchestrator restart, external bind/unbind, and public/socialware writes are denied or redirected to read-only states;
- live workers owned by the session are stopped or reaped;
- invited agents and users are not destroyed;
- existing message history and audit remain intact.

This likely needs a persisted lifecycle projection, not just Kind liveness. A terminated Kind alone cannot answer "archived" versus "crashed/not started/deleted."

## What Happens To Related Surfaces

### Live Session Process

Archive should transition the session into a durable `archived` state before process teardown. After archive, lazy spawn/ensure paths must not silently revive it as active.

The implementation should fail loudly if an archived session receives active actions such as `session.send`, `session.join`, `session.attach`, `session.remove_participant`, `external_mirror.bind`, or orchestrator restart.

### SessionManager

Stop `Ezagent.Session.SessionManager` for the orchestrator, as current permanent destroy already does. The stopped executor must not be recreated by cold-restart self-heal for an archived session.

Required invariant: `SessionManager.ensure_for_session/1` returns a no-op or archived error when the session lifecycle projection says archived.

### Orchestrator And Spawned Members

Archive should reap session-spawned workers and the orchestrator using the existing provenance model:

- spawned worker: reap only if it carries the session spawn facet and is in the owner's durable lineage;
- invited agent: leave alive, remove/disable only its session membership;
- user: never destroy;
- orchestrator: reap as session-owned runtime.

This follows the existing `Session.Teardown` security model and avoids inventing a new authority path.

### Routing Rows

Archive should disable or prune session-created routing rows (`created_by == session_uri`) so archived sessions cannot keep receiving traffic. The current permanent cascade force-deletes these rows. For archive, the lead should decide between:

- **disable rows** so archive could be reversible later; or
- **delete rows** and make unarchive out of scope.

Recommendation for v1: delete/prune rows and declare unarchive out of scope. It matches the current teardown primitive and avoids a half-supported restore promise.

### ExternalMirror Bindings

Archive must stop outbound mirrors. Do not rely only on process termination; the projection table can rehydrate workers on restart.

The archive implementation needs one of:

- unbind every `external_mirror_bindings` row for the session through `Ezagent.ExternalMirror.unbind/4`; or
- add a lifecycle-aware binding state so the BootReconciler and `Behavior.ExternalMirror.activate/2` skip archived sessions.

Recommendation for first slice: unbind all rows during archive and assert no worker is recreated after restart.

### Public / Socialware Surfaces

Archive must revoke public web access, even when the installed socialware definition still has `visibility_policy.web_anon_access: true`.

`Ezagent.Socialware.PublicView.web_anon_access?/1` currently derives access from installed definitions. It should also fail closed for archived sessions. Existing anon users/bindings should stop receiving live access; whether to reap anon users immediately or let GC handle them is a product decision.

Recommendation for first slice: make public access return false and disconnect/deny new joins; defer eager anon-user reaping to a later cleanup pass unless required by privacy policy.

### Working Copy / Template Links

Archive should preserve `template_working_copy`, `parent_template_uri`, source template links, and installed socialware ConfigObjects. These are provenance and inspection data.

Permanent delete may later remove or tombstone these records under a retention policy, but archive should not.

### Message History

Archive should preserve messages. It may freeze new writes. Message history is the audit/debug artifact and should remain visible to authorized operators.

Permanent delete needs an explicit retention/privacy policy before it removes messages.

### Audit / Provenance

Every lifecycle transition needs an audit record with at least:

- `authorized_operator_uri` - the human/entity whose authority allowed the action;
- `execution_principal_uri` - the runtime principal that executed the cascade, if different;
- `target_session_uri`;
- `lifecycle_action` - `archive`, `end`, or `delete`;
- `reason`;
- `requested_at` / `completed_at`;
- outcome counts: workers reaped, invited members detached, routing rows removed, external bindings removed, public access disabled.

No silent best-effort-only archive: best-effort teardown can be acceptable for cleanup, but the lifecycle transition itself must leave inspectable evidence of partial failures.

## Authorization

Do not finalize a new CapBAC rule in this workstream without Allen.

Recommended authorization shape for first implementation:

- owner may archive their own session;
- workspace/system admin may archive sessions within authority;
- ordinary members may not archive;
- `session.remove_participant` and chat participation caps are insufficient;
- execution should enter through a new dispatch action on the Session Kind, not a LiveView-only check or direct VM primitive.

Open CapBAC decision for Allen:

Should archive use a new session lifecycle cap, for example:

`cap(:session, Ezagent.Behavior.SessionLifecycle, :archive, <session_uri>, <workspace>)`

or should it extend `Ezagent.Behavior.Session` with an `:archive` action/cap?

Recommendation: add a small domain behavior or clearly named Session action only after naming review. Do not expose generic `manage.delete` as the Agent Console authority; `manage.delete` is too destructive and not product-specific enough for archive semantics.

Execution authority should not be "reconstructed orchestrator authority." The operator's authority should authorize the lifecycle transition. The internal cleanup can run as session-domain execution after that transition, but the audit must keep the operator and execution principal separate.

## Safe First Implementation Slice

1. Add a durable session lifecycle projection with `active | archived` and audit fields.
2. Add a dispatch-gated `archive` operation authorized by owner/admin only.
3. On archive:
   - persist archived state first;
   - stop SessionManager;
   - reap orchestrator and session-spawned workers using the existing teardown provenance checks;
   - prune session-created routing rows;
   - unbind ExternalMirror bindings;
   - make public/socialware access fail closed;
   - leave messages, audit, working copy, template links, installed config, invited agents, and users intact.
4. Update Agent Console to show archived sessions read-only and hide them from active lists by default.

## Explicit Deferrals

- Reversible unarchive.
- Permanent delete of message history and audit rows.
- Retention-policy GC for archived sessions.
- Eager anon-user reaping on archive.
- Bulk archive/delete.
- Cross-workspace lifecycle administration beyond existing system/admin authority.
- Rewriting the existing permanent `Lifecycle.destroy(session)` cascade.

## Required Invariant Tests Before Implementation Merge

- Archived session cannot be revived by lazy spawn, cold restart, or `SessionManager.ensure_for_session/1`.
- Archived session rejects active actions: send, join, attach, participant mutation, external mirror bind, orchestrator restart.
- Archive reaps session-spawned workers and orchestrator but does not destroy invited agents or users.
- Archive prunes or disables all routing rows with `created_by == session_uri`.
- Archive removes or disables ExternalMirror bindings and boot reconciliation does not recreate workers.
- `PublicView.web_anon_access?/1` returns false for archived sessions, even when installed definitions allow anonymous web access.
- Message history remains readable to an authorized operator after archive.
- Audit records include operator, execution principal, target session, action, reason, and completion outcome.
- Non-owner member cannot archive; owner/admin can; checks happen at dispatch, not only in LiveView.

## Open Decisions For Allen

1. Product wording: should v1 say "Archive session", "End session", or expose both?
2. Should archive be reversible? If yes, routing rows and external bindings need disabled/tombstoned state instead of deletion.
3. Is public/socialware archive supposed to eagerly reap anon users, or only block future access and rely on GC?
4. What is the retention policy for permanent delete of messages/audit/config?
5. Which CapBAC subject should own archive authority: a new lifecycle behavior or `Ezagent.Behavior.Session` action?
6. Should workspace admins archive any session in workspace, or only owners plus system admins?

## Merge Guidance

Do not merge a destructive Agent Console delete button from this workstream.

Mergeable next step is a small archive design/implementation PR with the invariant tests above. Permanent delete can use the existing cascade as an implementation ingredient later, but only after product retention and CapBAC decisions are explicit.
