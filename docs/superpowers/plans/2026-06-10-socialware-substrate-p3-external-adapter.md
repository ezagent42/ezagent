# Socialware Substrate P3 — ExternalAdapter (generalize ExternalMirror + fold CustomerFeed) Implementation Plan

> **STATUS: v1 DRAFT (written in parallel while P2.5c implements).** P3 *implementation* must NOT start until **P2.5c is merged** — P3 touches `CustomerFeed` / settlement-delivery files that P2.5c also edits (concurrent edits would conflict). This plan is grounded in `origin/main` + spec §6 P3; it gets the codex adversarial-review treatment (the per-phase ritual) AFTER P2.5c merges, so it is vetted against the *settled* delivery model (committed-cursor + post-parent-commit ordering). Treat the task bodies below as the design + sub-PR decomposition, not yet the final bite-size steps.

> **For agentic workers:** REQUIRED SUB-SKILL once finalized: superpowers:writing-plans → subagent-driven-development. Every subagent touching `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.

**Goal:** Unify the two external-projection paths (the Feishu **mirror** and the customer **feed/SPA**) onto ONE adapter contract, and wire the socialware **publisher READ API** with a **scoped cap boundary** so an external adapter reads a session's published stream without the chat-publisher authz widening. After P3: "render a session to an external system" is one declaration (an `ExternalAdapter`) + one durable source (the P2.5 committed-delivery cursor / the Publisher trunk as advisory wake-up), for both Feishu and the browser SPA.

**Architecture (grounded in the existing code):**
- The external-mirror domain ALREADY has the adapter abstraction to generalize: `Ezagent.ExternalMirror.Adapter` (behaviour — `adapter_id/0`, `binding_module/0`, `cap_subject/0`, `target_ownership_check/2`, `event_to_payload/1`) + `Ezagent.ExternalMirror.AdapterRegistry` (`register/1`, `lookup/1`, `list/0`) + per-binding `Binding`/`Worker` GenServers owning transport. Spec: `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`. **P3 lifts this into a general `Behavior.ExternalAdapter` (or extends `ExternalMirror.Adapter`) that BOTH the Feishu mirror AND the customer feed implement** — the Feishu adapter is the existing `event_to_payload` (slice-change → Lark payload); the customer adapter's `event_to_payload`/render is the `customer_tree` json-render projection over a Phoenix Channel (today's `CustomerFeed` + `CustomerChannel` + `customer_app.js`).
- **Durable source = the P2.5 committed-delivery cursor**, NOT the trunk. `CustomerFeed.committed_deliveries_since/2` + `latest_cursor/1` (P2.5b, merged) are the cursor-addressable replay; the customer adapter replays committed deliveries since its cursor on connect / on advisory wake-up. The Publisher trunk event (`Publisher.Event`, slice-change) is the **advisory wake-up only** — losing it never loses a delivery (the adapter catches up from the cursor). This preserves the committed-status gate + outbox idempotency (spec §6 P3 CRITICAL).
- **Publisher READ API + scoped cap (the deferred-from-P0 piece + codex #711 HIGH).** P0 put `Ezagent.Behavior.Publisher.SessionImpl` on `SocialwareSession` (trunk slice only; read-API + cap deferred). P3 wires the read-API dispatch (`snapshot`/`history`/`subscribe_from`) on `SocialwareSession` AND scopes its authz to a **per-instance / member / owner** cap — it MUST NOT reuse the broad `kind: :session` chat publisher cap (because `Session` + `SocialwareSession` share `type_name :session`, a `kind: :session` publisher grant would let a chat/Feishu workspace cap read `SocialwareSession`'s INTERNAL `:turns`/`:surface`/`:config_updates` slice payloads through the ring). The external customer adapter reads ONLY the committed-delivery projection (not the internal slices); the publisher read-API + scoped cap is for adapters/peers that legitimately follow the trunk.

**Tech Stack:** Elixir 1.19/OTP 27 — `apps/ezagent_domain_external_mirror` (Adapter/Registry/Binding), `apps/ezagent_domain_socialware` (CustomerFeed → adapter, SocialwareSession publisher read-API + cap), `apps/ezagent_web` (CustomerChannel/SPA on the new path), `apps/ezagent_plugin_feishu` (mirror adapter conformance). ExUnit + the live agent-browser E2E.

---

## Sub-PR decomposition (each shippable + tested; ordered)

### P3-1 — Make pull/render adapters FIRST-CLASS (codex P3 rev1 HIGH-1: not via nil callbacks)
The existing `Ezagent.ExternalMirror.Adapter` contract is **push/binding-shaped**: `AdapterRegistry.register/1` + plugin boot require `{adapter_module, binding_module}` pairs; `BindingRegistry` requires `init/1` + `publish/2`; the Worker ALWAYS looks up a binding, calls `binding_module.init/1`, then `publish/2`. A Phoenix-Channel **pull** feed (customer feed) has NO per-binding external transport — representing it with `nil` `binding_module`/`target_ownership_check` would be rejected at boot or crash the Worker, and a dummy binding would blur the bind-time ownership/transport boundary.
So P3-1 introduces an explicit **adapter KIND axis** — `:push` (event → external transport, today's Feishu mirror: binding + worker + `event_to_payload/1`) vs `:pull` (render-on-demand over a caller-owned channel: `render/2` returning the `customer_tree` json-render; NO binding/worker/transport). Concrete changes (a real sub-PR, NOT optional callbacks on the old contract):
- `Adapter` behaviour: add `adapter_kind/0 :: :push | :pull`; for `:pull`, `binding_module/0` + `target_ownership_check/2` are **not required** (the behaviour splits required callbacks by kind); add `render/2` (session_uri, ctx → json-render map) for `:pull`.
- `AdapterRegistry.register/1` + `Plugin.adapters/0` boot: accept a `:pull` adapter WITHOUT a `{adapter, binding}` pair; gate/install hooks + Worker startup skip binding/worker for `:pull` (a pull adapter has no Worker — it's served by its caller's channel).
- Feishu mirror = `:push`, byte-identical. Gate: existing external-mirror + Feishu tests green; a new `:pull` test adapter registers + renders without a binding and does NOT spawn a Worker.

### P3-2 — Customer feed as a `:pull` ExternalAdapter over the committed cursor
Reimplement `CustomerFeed`/`CustomerChannel` as a registered `:pull` `ExternalAdapter` (`adapter_id: "customer_feed"`) whose:
- **source** = `committed_deliveries_since/2` (replay by cursor) + the gated snapshot (`committed_customer_visible` + the committed page from P2.5a/P2.5b);
- **wake-up** = the existing `{:customer_delivery}` PubSub (advisory) → triggers a replay from the channel's last cursor;
- **render** = `Surface.customer_tree` json-render (unchanged projection).
The `CustomerChannel` keeps its auth (`CustomerAuth`) + structural-workspace + cold-safe reads (P2.5a).

**ATOMIC join protocol — LOWER-BOUND cursor (codex P3 rev1 HIGH-3 + rev2 HIGH-1).** Two races: snapshot-before-subscribe (rev1), AND — even subscribing first — the snapshot CONTENT reads (messages, page) and a separate `latest_cursor` read are not atomic (`CustomerFeed.snapshot/2` does separate queries; `customer_page` does its own reads), so a commit landing BETWEEN the content read and a `cursor = latest_cursor` read would store cursor N without having rendered N → permanent skip. Fix with a **lower-bound cursor that overlap-covers** (no DB transaction needed):
1. `subscribe` to the `{:customer_delivery}` topic FIRST.
2. capture `lower = CustomerFeed.latest_cursor(session)` BEFORE reading snapshot content.
3. take the gated snapshot (content) + render it.
4. immediately replay `committed_deliveries_since(lower)` once, and on EVERY subsequent advisory; the connection's stored cursor only advances to the max id actually replayed.
Because `lower` is captured before the content read, any delivery included in the snapshot has id ≥ a value ≤ `lower`'s successor, and any commit at/after `lower` is re-included by the replay (idempotent by committed_seq id — re-delivering an already-shown row is a no-op). So a delivery can be re-delivered (harmless) but NEVER skipped. Gate: a **join-race test** with the commit injected BETWEEN the snapshot CONTENT read and the first replay (the narrower window codex flagged) AND the advisory dropped → assert the delivery is still rendered via the lower-bound replay, not lost.

Gate: customer SPA render/deny tests green on the new path; the P2.5 **leak test** + **wake-up-loss test** still hold; the new join-race test; cursor replay is idempotent (no double-delivery — keyed by committed_seq id).

### P3-3 — SocialwareSession publisher READ API via a DISTINCT behavior + cap (codex #711 HIGH + P3 rev1 HIGH-2)
**A scoped cap alone is NOT enough, and reusing `Publisher.SessionImpl` does NOT work.** The runtime derives the needed cap from `kind_module.type_name()` + the registered behavior + the action. `SocialwareSession.type_name/0` is `:session` (same as chat `Session`). So if P3 registered the EXISTING `Publisher.SessionImpl` read actions on `SocialwareSession`, the needed cap would be `{kind: :session, behavior: Publisher.SessionImpl, action: snapshot|history|subscribe_from}` — which an existing BROAD `kind: :session` `Publisher.SessionImpl` grant (held by chat/Feishu) would STILL match (kind axis identical), re-opening the widening; and a Surface/Chat member cap would NOT match (wrong behavior). Also `Publisher.SessionImpl.data_owner/1` delegates to `Ezagent.Entity.Session.owner/1`, not a socialware owner/member model.

So P3-3 introduces a **DISTINCT socialware publisher-read behavior** (e.g. `Ezagent.Behavior.SocialwarePublisherRead`, registered ONLY on `SocialwareSession`) exposing `snapshot`/`history`/`subscribe_from` over the same Publisher ring, with:
- its OWN `cap_subject` / action set → a `{behavior: SocialwarePublisherRead, …}` needed-cap that a chat `Publisher.SessionImpl` grant can NEVER match (different behavior), closing the widening by construction;
- a socialware-specific `data_owner/1` (NOT `Session.owner`) — but note (codex rev2 HIGH-2) `default_grants_from_data_owner/2` emits ONE cap for the data_owner URI (the OWNER only); a non-owner MEMBER gets NO grant from it, and would hit CapBAC BEFORE the handler (an in-handler gate can't help if the member lacks a matching cap).

**MEMBER grant lifecycle (the part default-grant can't do alone).** A non-owner socialware member must hold a matching `SocialwarePublisherRead` cap. Mechanism: **grant a `SocialwarePublisherRead` cap scoped to the concrete `session://` instance to each member at socialware JOIN, and revoke at LEAVE** — explicit grant/revoke hooks on the socialware membership transitions (mirroring how chat join grants the first-owner cap, but for the read behavior + every member). The owner gets it via `data_owner` default-grant; members get it via the join hook. (Alternative considered: make the read action's needed-cap satisfiable by an existing member-scoped cap + enforce owner/member in-handler — but that reuses a broad member cap and is less precise; prefer explicit grant/revoke.) Specify the EXACT needed-cap shape + `data_owner` + the join-grant/leave-revoke.

Gate: the **authz-boundary test** — (a) an existing chat `{kind: :session, behavior: Publisher.SessionImpl}` cap CANNOT read a `SocialwareSession`'s `:turns`/`:surface`/`:config_updates` via the ring; (b) the **owner** CAN; (c) a **non-owner member** (granted at join) CAN — the positive member case codex required; (d) a non-member is denied; (e) after a member LEAVEs, the grant is revoked → denied.

### P3-4 — Feishu mirror on the generalized contract (conformance)
Confirm/port the Feishu mirror adapter to the generalized `ExternalAdapter` contract (likely a no-op rename if P3-1 keeps the push axis identical). Gate: Feishu mirror E2E green on the new path (slice-change → adapter publish → Lark).

---

## E2E acceptance (spec §7 — the merge gate for P3)
On the isolated fresh-seeded disposable stack (own ports, Tailscale `100.64.0.27`, never shared dev/prod), ALL green on the new adapter path:
- **Customer SPA agent-browser visual E2E** (the §36 standard): authenticated render of the json-render page + chat; unauthorized/cross-scope → denied. **This is where the live agent-browser E2E becomes the load-bearing gate** (P0-P2.5 were unit/integration-gated).
- **Feishu mirror E2E**: slice-change → adapter → Lark, on the new contract.
- **Non-visual gates carried forward:** the P2.5 **leak test** (no customer_visible page/messages before commit), the **wake-up-loss test** (drop the PubSub event → adapter still delivers via cursor replay), and the new **authz-boundary test** (chat `kind: :session` cap cannot read SocialwareSession internal slices).
- Full chat + socialware regression still green (P3 touches the customer-delivery + publisher-read paths that the core scenarios exercise).

---

## Open decisions (RESOLVED after codex P3 rev1 — confirm again at finalize post-P2.5c-merge)
1. **One contract or two axes? → RESOLVED: explicit `:push`/`:pull` adapter-KIND axis, pull is first-class** (codex HIGH-1). NOT nil callbacks on the push contract — pull adapters carry no binding/worker/transport and are split out at the behaviour + registry + boot + worker-startup level (P3-1).
2. **Cap for the publisher read-API → RESOLVED: a DISTINCT `SocialwarePublisherRead` behavior** (codex rev1 HIGH-2), NOT the chat `Publisher.SessionImpl` + a "scoped cap". OWNER authorized via `data_owner` default-grant; non-owner MEMBERS authorized via an explicit `SocialwarePublisherRead`-cap **grant at socialware join / revoke at leave** (codex rev2 HIGH-2 — default-grant alone only covers the owner) (P3-3).
3. **Cursor join protocol → RESOLVED: subscribe-FIRST, capture a LOWER-BOUND cursor before the snapshot content read, always replay `> lower_bound`** (codex rev1 HIGH-3 + rev2 HIGH-1) — overlap-covers both the snapshot↔subscribe AND the content-read↔cursor-read races without a DB transaction; idempotent by committed_seq id (re-delivery harmless, never a skip); cursor in-memory per connection.
4. **Does P3 need P2.5c, or only P2.5b?** P3 consumes `committed_deliveries_since` (P2.5b, merged). It does NOT depend on P2.5c's ordering internals — BUT it must not be IMPLEMENTED concurrently with P2.5c (file overlap in CustomerFeed/settlement). Sequence: P2.5c merges → finalize+codex this plan → implement P3.
5. **`SocialwarePublisherRead` vs in-handler gate** — confirm at finalize whether a separate behavior or an in-handler socialware owner/member gate is the cleaner realization (lean: separate behavior, matches needed-cap derivation).

---

## Why this is parallel-safe to PLAN now
Docs-only; touches no code; the P2.5c subagent edits `lib/`+`test/` on the `socialware-p2_5c-post-parent-commit` branch. This plan lives on its own `plan/socialware-p3-external-adapter` branch off `origin/main`. After P2.5c merges, rebase this plan onto the new main, run the codex adversarial-review loop, then implement.
