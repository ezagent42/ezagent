# Read-Plane Authorization: Unified-Mechanism Chokepoint + Anti-Bypass Gate — DESIGN

> **Status:** DESIGN — brainstormed live with Allen (2026-07-18), approved. Next = codex adversarial review → writing-plans → implement.
> **Author:** Claude (coordinator), with Allen.
> **Base:** `origin/main` @ `70ffafa85`. Branch: `feat/read-plane-authz-chokepoint`.
> **Relates:** jjkysy PR #1459 handoff `docs/together/2026-07-18/handoffs/read-plane-authz.md` (root-cause evidence, coordinator-verified) · uploads-person-token companion · cap-signing #1457 (the write plane whose landing exposed this).

---

## 0. The X problem — this is an EVOLVABILITY problem, NOT a security problem

The problem to solve is **not** "defend against a malicious reader." Allen's reframe (settled):

> **Developers casually bypass the unified data-access mechanism via a side-path; each bypass site becomes stale "legacy" the moment the unified mechanism is updated — silently inconsistent, surfacing later as downstream bugs.**

**The live first instance (not hypothetical):** cap-signing (#1457) hardened the WRITE plane — the dispatch chokepoint now verifies signed caps. But message READS are scattered **direct `Repo.all`** in LiveView data-loaders that never passed through any chokepoint, so the mechanism update **could not reach them**. Result: the "write-signed / read-ungated" inversion. Downstream symptoms (jjkysy #1459, coordinator code-verified):
- Any logged-in user reads any session's `:external_visible` messages via `?session=<uri>` deep-link (`MessageStore.recent_in_session` = raw `from(Message, where: session+workspace) |> Repo.all()`, zero membership check — `apps/ezagent_core/lib/ezagent/message_store.ex:142-174`).
- A rejected `self_join` still **observe-reads** the conversation (`conversation_actions.ex` moduledoc: "denial degrades to observe — the viewer still sees the conversation").
- kanban attachment download 403-for-everyone (`uploads_controller.ex` serve-time Message-table recheck is a *compensation* for the ungated read plane, and mis-fires on kanban attachments which write zero Message rows).

**Explicitly out of scope (settled with Allen):**
- **In-VM malicious code** — cannot be defended in one BEAM (cap-signing Path A bedrock) and is not the concern here.
- **Data-at-rest confidentiality** (DB dump / ops with SQL access) — a SEPARATE, deferred Path-B track (field-level cap-encryption, coupled with revoke-completeness). Noted so it is not conflated.

This spec is purely: **make the unified read mechanism structurally un-bypassable at *dev time*, so mechanism upgrades don't leave a legacy tail.** Closing the read-side info-disclosure is a *consequence*, not the framing.

---

## 1. The principle (system-wide, reusable)

> Every unified data-access mechanism = **[ ONE semantic chokepoint per (container-Kind × plane) ] + [ a fail-loud module-boundary gate forbidding the raw store/Ecto outside the chokepoint ]**.

- **Chokepoint** = the single place the mechanism (authz today; filtering / logging / future concerns tomorrow) is implemented. A mechanism update changes *one* place; all callers inherit it. This is what the read plane lacked, so cap-signing couldn't reach it.
- **Gate** = keeps it the *only* door over time. A new bypass fails CI, so no silent legacy accrues.

**Both halves are required.** Chokepoint without gate rots (devs add bypasses). Gate without prior consolidation = a huge per-callsite allowlist — exactly the write-side's current pain: `check_invariants` bans direct `KindSnapshot.upsert/delete` and bare `PubSub.broadcast` via **path-keyed allowlists** that go stale on every file move/rename (documented failures: `KindSnapshot.delete` missing from the delete allowlist; the chat→session rename breaking the PubSub allowlist). We avoid that by **consolidating first → the boundary is module-keyed with ~2 stable entries, not a path list.**

---

## 2. Why reads bypass the actor — and what NOT to change

The system is de-facto CQRS:
- **Writes (commands)** route to the target Kind's `Kind.Server` actor: `Invocation.dispatch` → `GenServer.call(session_actor, {:ezagent_dispatch, inv})` → the ActionSet chokepoint verifies the cap **inside that call** → the `:send` handler runs in the actor → `MessageStore.write/2` (`apps/ezagent_domain_session/lib/ezagent/behavior/session.ex:578`). The cap-check is "free" because the write must enter the actor anyway (state ownership).
- **Reads (queries)** hit the persisted projection directly: `WorldLive.handle_params` → `ConversationData.state_for` → `load_messages` → `MessageStore.recent_in_session` → `Repo.all` (`apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex:427`). **No `GenServer.call`, no actor, no chokepoint, no cap-check.**

Reads bypass the actor **by design and correctly**: routing every page-load read through the actor's single mailbox would serialize + block on cold actors (an OTP anti-pattern), and the data lives in the DB projection anyway. **We keep reads bypassing the actor.** The bug is not "reads skip the actor" — it is "reads skip the *cap-check*, which happened to live on the actor path." The fix moves the cap-check to the *read chokepoint*, executed **inline** (no actor).

---

## 3. The read-plane design

### 3.1 Authorization anchor = the container Kind

Everything readable sits in a containment hierarchy of Kinds:

```
workspace ⊃ session ⊃ message
                   ⊃ mount ⊃ attachment
workspace ⊃ agent
```

A principal reading at any level needs a **read-cap on the *direct container Kind* at that level** — not on the query, the table, or Ecto (which are semantically blind to the container). Two layers, cleanly separated:
- **Container read-cap** — gates access to the collection surface (may you touch session S's messages at all).
- **Row filter** — visibility / per-item membership within (which messages; e.g. `:external_visible` vs `:read_unfiltered`).

### 3.2 Cap-gated read chokepoints (per container, INLINE — not actor-dispatch)

One authorized-read module per container plane, e.g.:
- `SessionReads.messages(caller, session_uri, limit)` · `SessionReads.members(caller, session_uri)`
- `WorkspaceReads.sessions(caller, workspace_uri)` · `WorkspaceReads.agents(caller, workspace_uri)`
- `MountReads.attachment(caller, mount_uri, id)`

Each has the identical shape:

```elixir
def messages(caller, session_uri, limit) do
  with :ok <- Ezagent.Session.Membership.authorize(session_slice(session_uri), caller, session_uri) do
    {:ok, MessageStore.recent_visible_in_session(session_uri, limit)}   # unchanged Repo.all under it
  end
end
```

- **INLINE** — no `GenServer.call`; the actor stays bypassed (performance preserved).
- **Cheap** — `Membership.authorize/3` reads the container's *persisted* member-caps (roster ∧ held member-cap); the actor need not be running.
- **Reuse the existing predicate** — `Ezagent.Session.Membership.authorize/3` is ALREADY the read predicate on the external surfaces (`chat_feed.ex:137`, `external_feed.ex:402`, `socialware_publisher_read.ex:202`, both feed controllers, `session_config/admission.ex`). This spec merely extends the SAME predicate to the internal loaders that skipped it. No new authz semantics.

### 3.3 The gate — module boundary (fail-loud, dev-time)

The raw store read functions (`MessageStore.recent_in_session` / `recent_visible_in_session`, and the analogous list-reads) become callable **ONLY from the read-chokepoint modules + the framework-internal tier** (reconcile / GC / boot / snapshot-rehydrate — no principal). Any other caller → **CI red**.

Enforcement options (decide in the plan):
- The existing `mix ezagent.check_invariants` arch-gate mechanism (grep/AST), but **module-keyed** (caller module ∈ allowlist), not path-keyed; OR
- the `Boundary` library (compile-time module-dependency boundaries) if we want compile-time rather than CI-grep.

Either way the allowlist is ~2 stable **module** entries, not a path list.

### 3.4 Migration order (keeps the allowlist tiny — this is the crux)

1. **Build** the chokepoint modules (`SessionReads` / `WorkspaceReads` / `MountReads`).
2. **Migrate** every principal-facing reader (LiveView data-loaders, controllers) to call them; thread `caller` through where it isn't already.
3. **THEN** turn on the boundary gate. At this point the allowlist is empty except [chokepoint tier] + [framework-internal tier].

Gating *before* consolidating would force allowlisting all N scattered readers = the write-side's stale-path-list pain. Order matters.

---

## 4. Scope

**IN** — all *principal-facing* reads:
- LiveView data-loaders (`conversation_data.ex` message/member reads; session/agent list loaders).
- Controllers with principal-facing reads (`uploads_controller`, any API read surface).
- External feeds (`chat_feed` / `external_feed` / `socialware_publisher_read`) already apply the predicate → route them through the chokepoint too **for uniformity** (single implementation site), or leave in place and document them as already-compliant callers of the same predicate (plan decides; uniformity preferred so the mechanism has one home).

**OUT** — framework-internal reads (reconcile / GC / boot / snapshot-rehydrate / cap-store self-reads): no principal, not in the X. These are the boundary's allowed second tier.

**ATTACHMENT plane (the 403 symptom)** — `DownloadToken` gains an optional person-bound `grantee` (serve-time `caller == grantee`; no field → legacy recheck, zero-breakage), and the token is minted *inside* the cap-gated read (kanban click already dispatches cap-gated; chat-side pre-sign gets the `Membership.authorize` check). This is jjkysy's `uploads-person-token` companion, folded in as the attachment-plane instance of the same principle.

---

## 5. Non-goals / deferred

- **In-VM malicious defense** — out of scope (bedrock; a determined in-VM caller can still `import Ecto`). This gate is ratchet + review = catches *accidental/lazy* bypass (the actual X), not deliberate malice.
- **Data-at-rest confidentiality / field-level cap-encryption** — separate Path-B-level track (couples with revoke-completeness: static container key vs dynamic membership). Not this spec.
- **Write-plane side-table consolidation** — **STRETCH**: message/mount side-table *writes* funnel through `MessageStore.write/2` etc. but are "safe" only because their callers are cap-checked action handlers; a direct `Repo.insert(%Message{})` bypasses. Consolidating side-table writes to the same container-Kind domain APIs + collapsing the existing `KindSnapshot`/`PubSub` path-allowlists into module boundaries is a natural follow-on, deferred to keep this spec landable.

---

## 6. Acceptance criteria

1. **Info-disclosure closed** — a non-member hitting `?session=<uri>` for a session they don't belong to gets a fail-loud denial on the internal conversation read (was: full `:external_visible` read).
2. **Observe-degrade closed** — a rejected `self_join` viewer can no longer read the conversation.
3. **Performance preserved** — a member's read still works and adds **no `GenServer.call`** to the read path (assert the read path issues no actor round-trip; only one extra `Membership.authorize` against persisted state).
4. **Anti-bypass gate live** — adding a direct `MessageStore.recent_in_session` (or analogous raw store read) call outside a chokepoint module turns CI **red**.
5. **Attachment fixed** — a legit member downloads a kanban attachment successfully (403 gone); a leaked token presented by a non-grantee is rejected.
6. **No regression on existing feeds** — external feed reads use the byte-identical `Membership.authorize/3`; their behavior is unchanged.

---

## 7. Best-practice grounding (why this is not bespoke)

- **CQRS**: commands-via-aggregate / queries-via-projection is canonical; **query-side authorization** (the read model does not inherit the aggregate's authz) is a documented principle, and *forgetting it* is the classic CQRS pitfall — exactly what happened. The remedy (authorize at the query handler / read gateway) is standard.
- **Phoenix/Elixir**: "don't call `Repo` from the web/LiveView layer — go through a context API" is Phoenix's documented practice; the read chokepoint IS that context function, refined to also authorize. Bypassing the `GenServer` for scale reads is correct OTP. The module boundary is enforceable with the `Boundary` library or the existing arch-gate.
- **Domain specialization (ours)**: the authz anchor is the **container Kind** and the predicate reuses the cap model (`Membership.authorize/3`) — the ezagent-specific form of generic query-side authz.
