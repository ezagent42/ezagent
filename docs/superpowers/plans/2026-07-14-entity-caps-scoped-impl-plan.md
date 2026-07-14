# Entity Caps — scoped impl plan (patch the 3 real gaps + inbound facade)

**Status:** IMPL PLAN — lead-locked scope 2026-07-14 (Allen: "(ii) + 入向共享门面"). Awaiting codex review of the 2 real-risk pieces (A revoke-safety, D facade), then build.
**Supersedes:** the "grand unification" spec (`2026-07-14-entity-two-direction-caps.md`, v1-v3) — **NOT** doing the physical inbound rewrite. That exploration correctly concluded the async self-store is ~80% already built; this plan patches only the genuine gaps.
**Why scoped this way:** the decentralized async self-store already exists — `absorb_cap` (identity.ex:249-279) is the ISSUE→async-cast→grantee-self-store; `activate/2` (identity.ex:288-345) MERGES+PRESERVES caps (invariant 20, not overwrite); agents/users both snapshot their live slice; composition multi-edge revoke handled by `supported?/2`. The real gaps are narrow.

## Locked scope — 4 parts

| | gap | fix | scatter risk |
|---|---|---|---|
| **A** | grant/revoke delivery is **not durable** — `PendingDelivery` is ETS-bounded 100/URI (pending_delivery.ex), overflow → `DLQ` which is **diagnostic-only, no replay/ACK/retry** (dlq.ex) → a **revoke to a not-ready/overloaded entity is silently dropped = cap stays** | durable, retried, **ACK-on-grantee-commit** delivery for the cap handoff | **none** — one shared delivery layer everything flows through |
| **B** | no durable **outbound record** for general/mount grants (composition has `CompositionBinding`, recipe has `recipe_cap_binding`, general+mount have nothing) → granter can't reliably revoke/audit; #1376 reached for `socialware_mounts` | **one shared** `OutboundGrant` record (NOT a mount-specific table); mount is first consumer | **contained** — one abstraction, not per-subtype |
| **C** | grantee not in signature → retargeting | Phase-4 **PR #1386** (separate track, codex building) | none — `Cap.issue`/`verify` |
| **D** | inbound has two physical forms (user `caps_json` / agent `snapshot`) → **dev drift** | **`EntityCaps` access facade** (`load`/`persist`/`grant`/`revoke`) — uniform API, routes user→caps_json, agent→snapshot internally; **physical stores unchanged** | **killed** at the API layer — new code uses the facade, never raw stores |

**Not doing:** physical inbound-store unification (multi-day, high-risk, touches the CapBAC SSOT + 6 live users' data). The facade gives Allen's "no drift" without it.

## Phases (A + D + B parallelizable; C is the Phase-4 track; P5 depends on A+B+C+D)

### P1 (A) — durable-retry cap delivery  [core; the security fix]  (lead 2026-07-14: durable-retry now, sync-ACK deferred)
- **The real bug is silent DROP** (a grant/revoke to a not-ready/overflowed target lands in ETS-bounded `PendingDelivery` → diagnostic `DLQ`, lost forever). **The essential fix = durability + retry**, NOT a new ACK protocol.
- Give the cap grant/revoke handoff a **durable outbox** table (`{target, op, cap_id, status, attempts, next_retry}`) replacing ETS `PendingDelivery` **for these two op kinds only** (`:absorb_cap` / `:revoke_cap`); general chat delivery untouched. **Reuse the existing ready-drain/flush mechanism**, just DB-backed: target not-ready/overflowed → the op stays durably pending + retries on the target's `announce_ready`/recovery; **survives restart**. A revoke is **never dropped**.
- **"applied" = the grantee's absorb/revoke handler ran** (dispatch `:ok`). **Sync-ACK is DEFERRED** (lead: internal deployment doesn't need it — the threat is the silent drop, not the sub-second eventual-consistency window). Leave a **config hook** so **admin / manage / own** caps can later require sync-ACK/short-TTL for an external/adversarial deployment; do NOT build the sync path now.
- **Gate:** a revoke to a killed/overflowed target is provably retried-until-applied on recovery (not DLQ-dropped), surviving restart. `mix ci.local` green. High-risk-tier hook present but off by default.

### P2 (D) — `EntityCaps` inbound facade  [identity/domain; kills drift]
- New `Ezagent.EntityCaps` (or similar): `load(uri)` / `persist(uri, caps)` / `grant(uri, cap)` / `revoke(uri, cap)`. Internally routes user→`caps_json`, agent→`snapshot`-slice; hides the split.
- **Incrementally migrate** the ~15 direct `caps_json` sites (users.ex, entity/user.ex, behavior/identity.ex activate, anon_user, installation, orchestrator/caps, chat_feed_controller, mix tasks) + the snapshot-caps access **onto the facade** — new code MUST use it. Add an **arch-gate**: no NEW direct `users.caps_json` / raw snapshot-caps access outside the facade.
- Physical stores unchanged → **no SSOT rewrite, no live-user migration**.
- **Gate:** facade round-trips both user + agent caps; arch-gate rejects new raw access; existing tests green.

### P3 (B) — shared `OutboundGrant` record  [identity/socialware]
- One `outbound_grants` record + API: `record(issuer, decision_owner, grantee, cap, subtype, session_scope)` / `revoke` / `list_by(granter|grantee)`. Basis for revoke + audit.
- **Mount is the first consumer** — replaces #1376's `socialware_mounts`. `recipe_cap_binding` + `CompositionBinding` **may converge later** (not now; they work).
- **Gate:** mount records + revokes via `OutboundGrant`; enumerable by granter.

### P4 (C) — grantee signing  [Phase-4 track]
- = **PR #1386** (codex building). Entity-caps **consumes** it: `EntityCaps`/facade STORE path requires the artifact's `grantee_uri` == the receiving entity (§ PR #1386). No new work here beyond wiring the check at the STORE boundary once #1386 lands.

### P5 — rebuild mount on the new pieces  [unblocks kanban/#1374]
- Mount API (salvaged from #1376) = ISSUE (grantee-signed, C) → record `OutboundGrant` (B) → durable-ACK deliver (A) → grantee self-absorbs into its own slice (existing). Drop `socialware_mounts`/`MountRow`. `#1374` kanban rebases (consumer contract preserved).
- **Gate:** runtime mount survives restart (already does — grantee slice) + is revocable via `OutboundGrant` + delivered durably; kanban #1374 green on top.

## Sequencing / ownership
A, D, B land independently (no interdependency); C is the parallel Phase-4 track (#1386). P5 integrates once A+B+C+D exist. Coordinator (Claude) owns; may hand bounded sub-steps to codex. W29 demo runs on current main (Hello↔Kanban #1383 already merged; mount rework is post-demo).

## DoD
1. **A:** cap revoke/grant is durable-retried (never DLQ-dropped, survives restart); "applied" = grantee handler ran; sync-ACK deferred with a config hook for the admin/manage/own tier.
2. **D:** `EntityCaps` facade is the sole caps access API for new code (arch-gated); physical stores untouched; no live-user migration.
3. **B:** one shared `OutboundGrant` record; mount is a consumer; enumerable for revoke/audit.
4. **C:** STORE requires signed-grantee == self (via #1386).
5. **P5:** mount on A+B+C+D; `socialware_mounts` never lands; #1374 rebased green.
6. `mix ci.local` green throughout; no core-SSOT rewrite; no drift-permitting raw access added.

## Grounding
`absorb_cap` identity.ex:249-279 · `activate/2`+merge identity.ex:288-345 · `PendingDelivery` (ETS/bounded) pending_delivery.ex:1-32 · `DLQ` (no replay) dlq.ex:26-68 · `revoke_cap` grant.ex:103 · `caps_json` SSOT users.ex:27,81-120,436 + ~15 sites · snapshot core kind/server.ex,state_rebuilder.ex · composition `supported?/2` composition_binding.ex:125-221 · recipe binding recipe_cap_binding.ex:49-105 · Phase-4 grantee PR #1386.
