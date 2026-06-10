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

### P3-1 — Generalize the adapter contract (no behavior change)
Lift/rename `Ezagent.ExternalMirror.Adapter` into the general `Behavior.ExternalAdapter` contract (or keep the name + add the customer-render callback path). Add the render axis the customer adapter needs: alongside `event_to_payload/1` (push-to-external), an adapter may declare a **pull/render** surface (the `customer_tree` json-render snapshot for a Channel-served SPA). Keep Feishu's adapter byte-identical (it implements only the push axis). Registry unchanged. Gate: existing external-mirror + Feishu tests green; the contract additions are optional callbacks so the Feishu adapter is unaffected.

### P3-2 — Customer feed as an ExternalAdapter over the committed cursor
Reimplement `CustomerFeed`/`CustomerChannel` as a registered `ExternalAdapter` (`adapter_id: "customer_feed"`) whose:
- **source** = `committed_deliveries_since/2` (replay by cursor) + the gated snapshot (`committed_customer_visible` + the committed page from P2.5a/P2.5b);
- **wake-up** = the existing `{:customer_delivery}` PubSub (advisory) → triggers a replay from the channel's last cursor;
- **render** = `Surface.customer_tree` json-render (unchanged projection).
The `CustomerChannel` keeps its auth (`CustomerAuth`) + the structural-workspace + cold-safe reads (P2.5a). Gate: customer SPA render/deny tests green on the new path; the P2.5 **leak test** + **wake-up-loss test** still hold; cursor replay is idempotent (no double-delivery).

### P3-3 — SocialwareSession publisher READ API + scoped cap (codex #711 HIGH)
Wire `snapshot`/`history`/`subscribe_from` dispatch on `SocialwareSession` (the `Publisher.SessionImpl` read-API deferred from P0), authz-scoped to a **concrete session/member/owner** cap — NOT `kind: :session`. Gate: the **authz-boundary test** — a chat-only `kind: :session` publisher cap CANNOT read a `SocialwareSession`'s internal slices through the ring; a legitimate member/owner cap can. (Per P0's recorded boundary requirement: P3 must NOT reuse the broad chat publisher cap.)

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

## Open decisions (to settle when finalizing post-P2.5c-merge, via codex review)
1. **One contract or two axes?** Generalize `ExternalMirror.Adapter` in place (add an optional pull/render axis) vs. a new `Behavior.ExternalAdapter` superset. Lean: extend in place (least churn; Feishu unaffected) — confirm against the external-mirror spec's binding/worker coupling (the customer feed has NO per-binding external transport; it's a Channel pull, so the `binding_module`/`target_ownership_check` callbacks may be `nil`/optional for it).
2. **Cap shape for the publisher read-API** — the exact per-instance/member/owner cap tuple (reuse the socialware member/owner cap from the chat/Surface authz, scoped to the concrete `session://` instance). Must NOT be `kind: :session`.
3. **Cursor ownership** — does the customer adapter persist its replay cursor (per channel connection in-memory is enough, since the snapshot is the full committed state) or durably? Lean: in-memory per-connection (reconnect re-snapshots from cursor 0 / latest), since `committed_deliveries_since` + the gated snapshot are both complete.
4. **Does P3 need P2.5c, or only P2.5b?** P3 consumes `committed_deliveries_since` (P2.5b, merged). It does NOT depend on P2.5c's ordering internals — BUT it must not be IMPLEMENTED concurrently with P2.5c (file overlap in CustomerFeed/settlement). Sequence: P2.5c merges → finalize+codex this plan → implement P3.

---

## Why this is parallel-safe to PLAN now
Docs-only; touches no code; the P2.5c subagent edits `lib/`+`test/` on the `socialware-p2_5c-post-parent-commit` branch. This plan lives on its own `plan/socialware-p3-external-adapter` branch off `origin/main`. After P2.5c merges, rebase this plan onto the new main, run the codex adversarial-review loop, then implement.
