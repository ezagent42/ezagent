# Read-Plane Authorization: Unified-Mechanism Chokepoint + Anti-Bypass Gate — DESIGN

> **Status:** DESIGN v2 — brainstormed live with Allen (2026-07-18), approved shape; codex adversarial round 1 = NEEDS-REVISION (7 holes), all folded in v2. Next = codex confirm pass → writing-plans → implement.
> **Author:** Claude (coordinator), with Allen. Codex adversarial review round 1 grounded the coverage/consistency/layering fixes.
> **Base:** `origin/main` @ `70ffafa85`. Branch: `feat/read-plane-authz-chokepoint`.
> **Relates:** jjkysy PR #1459 handoff `docs/together/2026-07-18/handoffs/read-plane-authz.md` · uploads-person-token companion · cap-signing #1457 (the write plane whose landing exposed this).

---

## 0. The X problem — this is an EVOLVABILITY problem, NOT a security problem

Allen's reframe (settled):

> **Developers casually bypass the unified data-access mechanism via a side-path; each bypass site becomes stale "legacy" the moment the unified mechanism is updated — silently inconsistent, surfacing later as downstream bugs.**

**Live first instance (not hypothetical):** cap-signing (#1457) hardened the WRITE plane (dispatch chokepoint verifies signed caps). Message READS are scattered **direct `Repo.all`** in LiveView data-loaders that never pass through any chokepoint → the mechanism update could not reach them → "write-signed / read-ungated" inversion. Coordinator-verified symptoms (jjkysy #1459):
- Any logged-in user reads any session's `:external_visible` messages via `?session=<uri>` deep-link (`MessageStore.recent_in_session` = raw `Repo.all`, zero membership check — `apps/ezagent_core/lib/ezagent/message_store.ex:142-174`).
- Rejected `self_join` still observe-reads (`conversation_actions.ex` moduledoc: "denial degrades to observe").
- kanban attachment 403-for-everyone (serve-time Message-table recheck is a *compensation* for the ungated read; mis-fires on kanban attachments — zero Message rows).

**Explicitly out of scope (settled):** in-VM malicious code (bedrock — can't defend in one BEAM; not the concern); data-at-rest confidentiality / field-crypto (separate Path-B track, coupled with revoke-completeness). This spec = make the unified read mechanism **structurally un-bypassable at dev-time**, so upgrades don't leave a legacy tail. Closing the info-disclosure is a *consequence*.

---

## 1. The principle (system-wide)

> Every unified data-access mechanism = **[ ONE chokepoint per (query-scope × plane) ] + [ a fail-loud module-boundary gate forbidding raw `Repo`/Ecto access outside designated store-owner modules ]**.

- **Chokepoint** = the single place the plane's mechanism (authz + row-policy today; filtering/logging tomorrow) is implemented. A mechanism update changes one place; all callers inherit it. The read plane lacked this, so cap-signing couldn't reach it.
- **Gate** = keeps it the only door. New bypass → CI red → no silent legacy.

Both required. Chokepoint without gate rots; gate without prior consolidation = a huge per-callsite allowlist (the write-side's stale path-keyed `KindSnapshot`/`PubSub` allowlists). **Consolidate first → the boundary is module-keyed with a tiny stable exception set, not a path list.**

---

## 2. Two axes that shape the read mechanism

### 2.1 Why reads don't carry the cap-check (and what NOT to change)
De-facto CQRS. **Writes (commands)** enter the target Kind's actor: `Invocation.dispatch` → `GenServer.call(session_actor, {:ezagent_dispatch, inv})` → the ActionSet chokepoint verifies the cap **inside that call** → handler → `MessageStore.write/2` (`session.ex:578`). The cap-check is "free" — the write must enter the actor anyway (state ownership). **Reads (queries)** hit the projection directly: `WorldLive.handle_params` → `ConversationData.state_for` → `load_messages` → `MessageStore.recent_in_session` → `Repo.all` (`conversation_data.ex:427`). **No dispatch, no chokepoint, no cap-check.** Reads must NOT be routed through the actor's mailbox (serializes + blocks on cold actors — an OTP anti-pattern); the fix moves the cap-check to the *read chokepoint*, NOT into the actor.

### 2.2 Query-scope taxonomy (codex round-1 hole #1/#2 — the anchor is NOT universally "container member-cap")
Every principal-facing read has a **query scope** and an **access policy**; the chokepoint enforces the policy for its scope:

| scope | example | access policy (what the chokepoint checks) |
|---|---|---|
| **single-container** | session messages/members; a mount's attachment | member-cap on the container (`Membership.authorize/3`) **∪** the container's declared open policy (e.g. public-view `PublicView.web_anon_access?/1` for public sessions — `external_feed.ex:405-430`) |
| **multi-container (workspace-scoped list)** | workspace's sessions / agents | authorize the **workspace scope** (workspace membership), AND constrain every returned row to a container the caller may see (per-row member-cap filter) |
| **global / operator** | `AdminData` registry/template list-all, external-mirror (`admin_data.ex:64-73,201-225,297-310`) | an **operator/admin cap** (no container anchor exists); NOT a member-cap |

So the anchor is **"query scope + named access policy"**, not universally "direct-container member-cap." A read with no container (global registry) authorizes an operator cap; a public session authorizes via the open policy; a normal session authorizes membership.

---

## 3. The read-plane design

### 3.1 Cap-gated read chokepoints (per scope; own BOTH authz and row-policy)
Chokepoint modules, **placed in the resource-owning domain** (codex hole #5, layering — see §5):
- `SessionReads` (in `ezagent_domain_session`) — `messages(caller, session, opts)`, `members(caller, session)`.
- `AgentReads` (in `ezagent_domain_agent`) — `list(caller, workspace)`.
- `MountReads` — attachment/mount reads.
- `OperatorReads` — global/operator list-all (registry, external-mirror), authorizing an operator cap.
- A **composition layer** (world / `domain_ui`) may compose these (e.g. a workspace overview calling `SessionReads` + `AgentReads`) but is **forbidden from touching raw stores** (enforced by the gate).

Each chokepoint does, in order:
1. **Access-policy check** for its scope (member-cap `Membership.authorize/3` ∪ open-policy ∪ operator-cap) → fail-loud on deny.
2. **Row-policy ownership** (codex hole #7) — the chokepoint itself sources/verifies the caller's `:read_unfiltered` authority and chooses `recent_visible_in_session` (external-visible) vs `recent_in_session` (unfiltered admin view). It does NOT accept a caller-supplied "which rows" flag (that would re-open a caller-selectable bypass). Today `conversation_data.ex:425-446` picks this from `caller_caps`; that logic moves *into* the chokepoint.
3. **Query** the raw store.

### 3.2 Consistency contract (codex hole #3 — CORRECTED)
The earlier draft's "persisted-only, no-actor" claim was **wrong and is withdrawn.** The existing predicate `Membership.authorize/3` is **live-first**: it obtains the session slice via `Kind.get_slice/2` and caps via `EntityCaps.load/1` (live-first, `entity_caps.ex:42-66`), either of which **may synchronously call the Kind actor** (`slice_access.ex:18-29`). This is correct and is what we reuse **unchanged** — critically, it means an **async at-join member-cap grant that isn't yet persisted is still seen** (member_cap.ex:42-59,254-268), so fresh joins are NOT falsely denied. Contract, stated explicitly + tested:
- **Authorization is live-first** (identical to the existing feeds `chat_feed.ex:126-145` / `external_feed.ex:402`), so it reflects just-granted membership; cost is one predicate call per *read* (not per row), acceptable, and may warm/touch the container actor exactly as the feeds already do.
- The window between `authorize` and the independent `Repo.all` is a **point-in-time authz check** (a membership change in that window is not retroactively enforced) — this is standard and accepted, and documented as the contract rather than promised away.

### 3.3 The anti-bypass gate (codex hole #6 — ban raw `Repo`/Ecto, not just store functions)
- The **only** modules permitted to call `EzagentCore.Repo` / Ecto for these planes are the designated **raw-store-owner modules** (`MessageStore`, the mount/agent/registry stores) + a **narrow internal-read gateway** (§3.4).
- Every other module — presenter tiers (LiveView loaders, controllers), the read chokepoints' *callers*, the composition layer — is **CI-red on any direct `Repo`/Ecto read**. This closes the `AdminData` direct-`Repo.all` recreation of the bypass (`admin_data.ex:297-310`), which a store-function-only ban would miss.
- Enforced module-keyed via `mix ezagent.check_invariants` (or `Boundary` lib). Allowlist = {store-owner modules, internal gateway, chokepoints} — a small stable module set, NOT paths.

### 3.4 Internal-read gateway (codex hole #4 — narrow, not a whole-module exemption)
Framework-internal reads with no principal (reconcile / GC / boot / snapshot-rehydrate / the `Delivery` at-most-once **replay** read `delivery.ex:381-395`) go through a **dedicated narrow gateway module** (e.g. `InternalReads`), NOT a blanket "this whole module is exempt." Rationale: `Delivery` contains a legit raw replay read; a module-level exemption could not distinguish it from a future principal-facing read added to the same module. The gateway is an explicit, enumerable set of internal read functions; the gate allows only it (+ store-owners + chokepoints).

### 3.5 Migration order (consolidate → migrate → gate)
1. **Build** the chokepoints + the internal gateway.
2. **Migrate** every principal-facing reader to a chokepoint: LiveView loaders (`conversation_data.ex`), controllers, `AdminData` global reads → `OperatorReads`, **and the existing feeds** (`chat_feed`/`external_feed`) → route through `SessionReads`, **folding their public-view policy into the chokepoint's access-policy** (codex hole #4b: public-view belongs in the principal chokepoint, not scattered in the feed). Framework-internal raw reads → the internal gateway.
3. **Gate** — turn on the module-boundary + the direct-`Repo` ban. Allowlist ≈ the small module set above.

---

## 4. Scope

**IN** — all principal-facing reads: LiveView loaders; controllers (`uploads_controller`); **global/operator reads** (`AdminData` registry/template/external-mirror); **public-view** session reads; the external feeds (routed through the chokepoint, policy folded in — NOT "left in place").
**OUT** — framework-internal reads → the narrow internal gateway (not the X, but must be an explicit gateway, not an implicit exemption).
**ATTACHMENT plane** — `DownloadToken` gains optional person-bound `grantee` (serve-time `caller == grantee`; no field → legacy recheck, zero-breakage), minted inside the cap-gated read. (jjkysy `uploads-person-token`, folded as the attachment instance.)

---

## 5. Layering (codex hole #5 — real dependency cycle; drives module placement)

Verified against `mix.exs` deps: `ezagent_domain_session` depends on core/identity/workspace/agent; `ezagent_domain_workspace` depends on agent; `ezagent_domain_agent` on core. Therefore:
- `SessionReads` lives in **`ezagent_domain_session`** (already deps `Membership` + `MessageStore` — no cycle). ✓
- A **monolithic `WorkspaceReads.sessions/agents` cannot live in `ezagent_domain_workspace`** — it would need session, but workspace→session cycles (workspace is below session). ✗
- Therefore **split workspace-scoped reads by resource-owning domain**: session-list logic in `ezagent_domain_session`, agent-list logic in `ezagent_domain_agent`. Any higher-level "workspace overview" composition lives in the world/UI layer and is **forbidden from touching raw stores** (composes chokepoints only).

---

## 6. Non-goals / deferred
- In-VM malicious defense (bedrock; ratchet+review catches accidental/lazy bypass, the actual X, not deliberate malice).
- Data-at-rest confidentiality / field-level cap-encryption (separate Path-B track + revoke-completeness).
- **Write-plane side-table consolidation** — STRETCH: side-table *writes* funnel through `MessageStore.write/2` but are "safe" only because callers are cap-checked action handlers; a direct `Repo.insert(%Message{})` bypasses. Consolidating side-table writes + collapsing the `KindSnapshot`/`PubSub` path-allowlists into module boundaries is a natural follow-on, deferred to keep this landable.

---

## 7. Acceptance criteria
1. **Info-disclosure closed** — non-member `?session=<uri>` internal read → fail-loud denial (was: full `:external_visible` read).
2. **Observe-degrade closed** — rejected `self_join` viewer cannot read.
3. **Fresh-join not falsely denied** — a member whose at-join grant is not yet persisted CAN read (live-first authorize sees it).
4. **Public-view preserved** — an anon/non-member on a declared public session CAN read, via the chokepoint's open policy (not via a bypass).
5. **Global/operator gated** — `AdminData`-style registry list-all requires an operator cap through `OperatorReads`; a non-operator principal is denied.
6. **Row policy preserved** — a `:read_unfiltered`-holder still gets unfiltered rows *through the chokepoint*; a non-holder cannot obtain them by any caller flag.
7. **Anti-bypass gate live** — adding a direct `MessageStore.recent_in_session` **OR a direct `EzagentCore.Repo.all`** in a presenter/chokepoint-caller module → CI red.
8. **Perf** — read path adds no per-row actor round-trip; one live-first predicate call per read (same cost class as existing feeds).
9. **Attachment** — legit member downloads kanban attachment (403 gone); leaked token by non-grantee rejected.
10. **No feed regression** — feed reads produce byte-identical results after routing through the chokepoint.

---

## 8. Best-practice grounding
- **CQRS**: commands-via-aggregate / queries-via-projection is canonical; **query-side authorization** is a documented principle and forgetting it is the classic pitfall we hit; the remedy (authorize at the query handler / read gateway) is standard.
- **Phoenix/Elixir**: "don't call `Repo` from web/LiveView — go through a context API" is documented practice; the chokepoint IS that context function, refined to authorize + own row-policy. Bypassing the `GenServer` for scale reads is correct OTP. The module boundary is enforceable via `Boundary` or the existing arch-gate.
- **Domain specialization (ours)**: the authz unit is **query scope + named access policy** anchored on the container Kind where one exists, reusing the cap model (`Membership.authorize/3`) — the ezagent form of generic query-side authz.
