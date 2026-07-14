# Codex Handoff — entity-caps scoped patch (A durable-retry / B outbound record / D facade)

**Plan:** `docs/superpowers/plans/2026-07-14-entity-caps-scoped-impl-plan.md` (lead-locked scope).
**Repo:** esr-ng. **Target branch:** `feat/entity-caps-scoped` (you own it; land A/B/D as bounded sub-steps continuously; coordinator reviews + merges to `main`).
**Do NOT** do the grand physical caps unification. This is a **patch on the existing async self-store** (already ~80% built).

## Non-negotiable constraints (lead-locked — do not re-litigate)

1. **No core SSOT rewrite.** `users.caps_json` stays the user-caps SSOT; the 6 live users are NOT migrated. `snapshot` stays the agent store. You wrap them, you don't replace them.
2. **A = durable-retry, NOT sync-ACK.** The bug is silently-dropped grant/revoke (ETS-bounded `PendingDelivery` → diagnostic `DLQ` with no replay). Fix = durability + retry. **Do NOT build a synchronous ACK protocol** — leave only a config hook for the admin/manage/own tier.
3. **B = ONE shared `OutboundGrant` record**, not a mount-specific table. Mount is the first consumer; `recipe_cap_binding`/`CompositionBinding` are NOT migrated onto it now.
4. **D facade wraps, does not replace.** Physical stores unchanged.
5. **P5 (mount rebuild) is NOT in this handoff** — it comes after A+B+C land and Phase-4 #1386 lands. Don't touch `#1376`/`socialware_mounts` here.
6. Each sub-step: full `mix ci.local` green + rebased on current `main` before self-merge to the target branch. Elixir via editor (never `cat >>`); `MIX_TEST_PARTITION` for parallel test runs.

## Sub-step A — durable-retry cap delivery  [core]

- Add a **durable outbox** (DB table `cap_delivery_outbox` or similar): `{id, target_uri, op (:absorb_cap|:revoke_cap), cap_id/artifact, status (:pending|:applied|:dead), attempts, next_retry_at, inserted_at}`.
- Route **only** `:absorb_cap` (grant) and `:revoke_cap` (revoke) dispatch through it; general chat delivery keeps ETS `PendingDelivery` (`pending_delivery.ex`). At `Ezagent.Identity.absorb_cap/2` (identity.ex:249-279) and `revoke_cap` (grant.ex:103): persist an outbox row, then dispatch; on target not-ready/`{:error,:buffer_full}`/no-actor, leave `:pending` + schedule retry.
- **Drain on recovery**: reuse the ready-drain trigger (`Kind.Server` `announce_ready`, which today flushes `PendingDelivery`) to also drain the outbox for that URI; a periodic retry sweeper handles crashed-mid-delivery. Mark `:applied` when the grantee handler returns `:ok`. Survives restart (DB-backed).
- **Config hook** `require_sync_ack: [admin, manage, own]` (default `[]` = off) — a stub that will later force sync-ACK/TTL for those cap classes. Build the hook point, NOT the sync path.
- **Gate:** kill/overflow a target, issue a revoke, assert it is retried-until-applied on recovery (not DLQ-dropped) and survives a restart. Existing delivery tests green.

## Sub-step B — shared `OutboundGrant` record  [identity/socialware]

- Add `Ezagent.OutboundGrant` (schema `outbound_grants` + API): `record(%{issuer, decision_owner, grantee, cap, subtype, session_scope, access})` / `revoke(id|natural_key)` / `list_by_granter(uri)` / `list_by_grantee(uri)`. `subtype ∈ :runtime_mount | :composition | :recipe | :ownership | :structural | :genesis` (only `:runtime_mount` used now).
- It is the durable **granter-side** record of "I issued cap X to grantee Y" — the basis for revoke + audit. **No consumer beyond providing the API in this sub-step** (mount wires it in P5). Do NOT migrate `recipe_cap_binding`/`CompositionBinding` onto it.
- **Gate:** record + list_by_granter/grantee + revoke round-trip; per-tenant table registered (workspace_uri column) if the arch gate requires it.

## Sub-step D — `EntityCaps` inbound facade  [identity]

- Add `Ezagent.EntityCaps`: `load(uri)` / `persist(uri, caps)` / `grant(uri, cap)` / `revoke(uri, cap)`. Internally route: user URI → `users.caps_json` (existing `caps_from_caps_json`/encode/decode), agent/other → the snapshot-backed `:identity` slice. Hide the split behind this one API.
- **Migrate the direct `caps_json` call sites onto the facade** (users.ex, entity/user.ex, behavior/identity.ex `activate`, anon_user.ex, installation.ex, orchestrator/caps.ex, chat_feed_controller.ex, the 2 mix tasks — ~15 sites from the grounding index) + the raw snapshot-caps access. Behavior must be identical (pure refactor to route through the facade).
- **Arch-gate:** add a scan that **rejects NEW direct `users.caps_json` access or raw snapshot-caps mutation outside `Ezagent.EntityCaps`** (allowlist the facade + the migration tool). This is what kills future drift.
- **Gate:** facade round-trips user + agent caps; all existing identity/caps tests green (pure refactor); arch-gate active + green.

## Sequencing
A, B, D are independent — land as three separate sub-steps on `feat/entity-caps-scoped` (any order). C (grantee-signing) is Phase-4 **PR #1386** (separate track). P5 (mount rebuild on A+B+C+D) is a LATER handoff.

## Return (per dev-together contract)
Per sub-step: `mix ci.local` URL/log + rebase SHA + DoD line-by-line. Hand the validated target branch to the coordinator; do NOT merge to `main` yourself.

## Grounding
`absorb_cap` identity.ex:249-279 · `revoke_cap` grant.ex:103 · `PendingDelivery` pending_delivery.ex:1-32 · `DLQ` dlq.ex:26-68 · ready-drain `Kind.Server` announce_ready · `activate/2`+`caps_from_caps_json` identity.ex:288-345,400 · `caps_json` sites users.ex:27,81-120,436 / entity/user.ex:81-100 / anon_user.ex / installation.ex:302 / orchestrator/caps.ex:122 / chat_feed_controller.ex:45 / grant_migration.ex · Phase-4 grantee PR #1386.
