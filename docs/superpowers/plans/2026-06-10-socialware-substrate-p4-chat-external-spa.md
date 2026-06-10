# Socialware Substrate P4 — Chat External SPA View Implementation Plan

> **STATUS: v1 DRAFT (parallel planning).** P4 *implementation* depends on **P3** (the `:pull` ExternalAdapter contract + the browser/Channel SPA surface + the live-membership authz pattern) and must NOT start until P3 is merged. This plan is grounded in `origin/main` + spec §6 P4; it gets codex-reviewed now (Allen's "all P codex" ask) and FINALIZED + rebased against the as-built P3 before implementation. Treat the tasks as design + sub-PRs.

> **For agentic workers:** REQUIRED SUB-SKILL once finalized: superpowers:writing-plans → subagent-driven-development. Subagents touching `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.

**Goal:** Give a CHAT session an **external SPA view** — the same `customer_tree`/json-render browser surface the socialware customer feed uses (built in P3) — projecting the chat message slice, with the same auth/visibility model. This proves the substrate's "ANY session → external SPA" generalization: P3 built the adapter + surface for socialware; P4 shows it works for chat too, with NO chat-specific surface code. The internal chat operator view (`EzagentPluginLiveview.Views.ConversationView`) is unchanged.

**Architecture (builds entirely on P3's resolved patterns):**
- P3 made the customer SPA a `:pull` `ExternalAdapter` (`render/2` → `customer_tree` json-render, served over a Phoenix Channel, with a lower-bound-cursor join protocol + live in-handler membership authz). P4 registers a SECOND `:pull` adapter `adapter_id: "chat_feed"` whose `render/2` projects the **chat message slice** (`MessageStore` messages for the session, visibility-gated) into the same `customer_tree` json-render shape, and whose source/cursor is the **chat message ordering** (message id / `inserted_at`), NOT the socialware committed-delivery cursor (chat has no settlement model).
- **Auth/visibility = chat membership (codex-pattern from P3-3, reused).** A chat session has no "customer"; its external-SPA viewers are its **members**. So the chat_feed adapter authorizes via the SAME live, fail-closed in-handler chat owner/member predicate P3-3 specified (caller `%URI{}`; `:chat` slice readable; `owner_uri == caller` OR caller ∈ `members`; nil-owner/nil-caller denied) — NOT a customer token (the customer-token model is socialware-specific). Message visibility filtering reuses the chat slice's existing visibility (chat has no `operator_only`/`customer_visible` settlement gate; it gates by membership + per-message visibility if any).
- **No new browser/channel code.** The SPA (`customer_app.js` / `json_render.mjs`) + the Channel framework from P3 are reused; chat_feed plugs in as another `:pull` adapter. The only new code is the chat→`customer_tree` projection + the chat membership authz wiring + the chat message cursor.

---

## Sub-PRs

### P4-1 — Chat → `customer_tree` projection (pure)
A pure projection `chat_slice_messages → customer_tree` json-render map (mirroring `Surface.customer_tree` but over chat messages: render the message stream as text nodes / a container). Public + unit-tested for exact output. Gate: deterministic projection; visibility filter applied (only messages the viewer may see).

### P4-2 — `chat_feed` `:pull` adapter + chat message cursor
Register a `:pull` `ExternalAdapter` (`adapter_id: "chat_feed"`) using P3's pull axis: `render/2` = P4-1's projection; the join protocol = P3's lower-bound cursor BUT over the **chat message cursor** (a monotonic message ordering — confirm whether `MessageStore` exposes a stable per-session message cursor/id ordering suitable for `> cursor` replay, like `MessageRouting.inserted_at` or the message id; if not, the cursor primitive is a small P4 addition mirroring `committed_deliveries_since`). Reuse the P3 SPA + Channel. Gate: a chat session renders + live-updates via the external SPA; the P3 join-race + wake-up-loss guarantees hold over the chat cursor.

### P4-3 — Chat membership authz on the external read (live, fail-closed)
Wire the chat_feed read authorization to the SAME live in-handler chat owner/member predicate as P3-3 (reuse, do not re-invent). Gate: the **authz-boundary test** — a non-member CANNOT view a chat session's external SPA; a member/owner CAN; an ex-member (after leave) is denied via the live re-check; a nil/`:any`/malformed caller is denied.

---

## E2E acceptance (spec §7 — the P4 merge gate)
On the isolated fresh-seeded disposable stack (Tailscale `100.64.0.27`):
- **Chat external SPA agent-browser visual E2E:** a chat session is viewable via the external SPA (json-render of the message stream) by a member; a non-member / cross-scope is denied. Same §36 standard as P3's customer SPA.
- **Chat operator view UNCHANGED:** `ConversationView` (the internal LiveView chat view) renders identically; the external SPA is purely additive.
- Full chat regression (send/receive/join/leave/owner-first-join/cap grants) still green — P4 adds a read projection + adapter, touching no chat write/dispatch path.
- The P3 join-race + wake-up-loss + authz-boundary gates hold for the chat_feed adapter.

---

## Open decisions (settle at finalize, against the as-built P3)
1. **Chat message cursor** — does `MessageStore`/`MessageRouting` already expose a stable monotonic per-session ordering usable as the replay cursor (`> cursor`)? If yes, reuse it; if no, add a small `chat_deliveries_since/2`-style primitive mirroring `committed_deliveries_since/2`. Confirm at finalize.
2. **Visibility model** — chat has no socialware settlement gate; confirm chat's per-message visibility (if any) + that the membership gate is the sole external-read authority (it is, per the P3-3 pattern).
3. **One adapter or two?** `customer_feed` (socialware) + `chat_feed` (chat) are two `:pull` adapters sharing the SPA + Channel + the live-membership authz pattern but differing in source (committed cursor vs message cursor) + visibility. Confirm they stay two adapters (cleaner) vs one parameterized — lean: two, sharing the `:pull` machinery.

---

## Dependency + parallel-safety
Depends on P3 (the `:pull` adapter contract, the SPA/Channel surface, the live-membership authz predicate, the lower-bound cursor protocol). Docs-only to plan; implementation strictly after P3 merges. This plan finalizes + rebases against the as-built P3 before P4 code.
