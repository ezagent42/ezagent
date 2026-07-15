# dev-together review — 2026-07-15 (lead close · v1 interim)

> **Interim.** More is expected tonight (codex's no-tail build return, gaga's provisioning + #1405, more demo). This v1 captures the day through ~afternoon; it will be updated at true EOD.

**One-line:** the day the **CapBAC signing programme collapsed to `main`** — the entity-caps substrate, grantee-signing (adversarially proven), and the no-tail self-healing design (twice codex-reviewed → SOUND) all landed — while the **W29 demo was segmented-verified on real canary** (and CapBAC was confirmed *enforcing* live) and the **capability-auth-followup readers** shipped. The security foundation the week needed is now in place; what remains is codex's no-tail build, the demo's dev-loop provisioning, and the (deliberately deferred) enforce flip.

## §1 What landed (merged to `main`, 2026-07-15)

| area | PRs | who |
|---|---|---|
| **entity-caps A/B/D substrate** | #1409 durable delivery outbox + `OutboundGrant` ledger + `EntityCaps` facade + write-side arch gate (canary-deployed green) | **allen** (lead track; codex build) |
| **grantee-signing (C)** | #1386 spec amendment; #1410 finalize + **adversarial proof** (retargeting closed at Cap seam + `EntityCaps.load`; all 8 verify chokepoints receiver-aware, 0 gaps) | **allen** (lead track) |
| **cap-signing no-tail (design)** | #1413 self-healing spec **v3** + codex build handoff (two codex adversarial reviews → SOUND); #1414 handoff-convention fix; #1408 verdict/boundary fold | **allen** (lead track) |
| **capability-auth follow-ups** | #1406 program plan; #1412 **Task 3-6 readers** (LiveAuth/MemberCap/world-count → verified `EntityCaps`, fail-closed) + **email-inbound authority seam** (removed unsigned inline mint) | **gaga** |
| **W29 demo (segmented verify)** | #1416 real-canary partial-E2E evidence + blockers (CapBAC confirmed *denying* unauthorized kanban writes; 2 real bugs found); #1417 dev-loop provisioning architecture constraints | **gaga** (verify); **allen** (constraints) |
| **coordination / product** | #1420 gaga↔codex cap-gate overlap note; #1378 website-demo restructure + flywheel design-brief; #1421 ruihua daily | **allen** / **ruihua** |

(PRs authored `allenwoods` in the CapBAC stack are lead-track work driven via codex + coordinator tooling.)

## §2 Accounting (plan vs actual)

- **Planned (07-15 plan §1/§2):** head goal = W29 demo end-to-end first full run (gaga test → allen verify → ruihua polish); parallel lead track = accept codex's two returns → no-tail upgrade + enforce timing.
- **Actual:** the **CapBAC line dominated and largely completed** — entity-caps A/B/D accepted+merged+deployed, grantee-signing proven, no-tail designed+reviewed+handed off, auth-followup readers shipped. The **demo advanced to a rigorous segmented verification** (#1416) that pinned down the exact remaining gaps rather than a full E2E — an honest, high-value outcome. So the "lead track" over-delivered; the "head goal" (full demo E2E) is **not yet through**, now blocked on 4 concrete provisioning gaps (#1417).
- **Returns today:** `capability-auth-followups.md` (gaga), `demo-e2e-dispatch.md` + evidence (gaga), `ruihua-daily.md`, `notes/cap-gate-overlap-gaga-codex.md`.

## §3 Quality & risk

- **Two codex adversarial reviews on the no-tail spec caught real design flaws before any code** — v1 (7) and v2 (more): the load-bearing one being that `verify_for/2` accepts unsigned caps under dual-read, so using it as the "signed" classifier would make the whole audit a false-zero no-op. v3 fixes it (`signed_and_valid?/2`) + 8 others; coordinator-verified SOUND. **This is the spec→adversarial-review→revise loop paying for itself.**
- **CapBAC is proven enforcing in the live demo** (#1416: kanban write-config/create-card precisely capability-denied). The security we built all day actually bites in production context.
- **⚠ Enforce is (correctly) still OFF** — dual-read holds; the `require_signature:true` flip is a deliberate manual lead decision after the no-tail drain reaches audit=0 + a real-canary-data E2E.
- **gaga #1412 ↔ codex no-tail overlap** on the shared cap gate/chokepoint surfaces — recorded (#1420) + reconciliation relayed (codex rebase-merges on top of gaga's; email inbound already done). #1412 landed first; codex rebases.
- **Demo not-through is a real gap, honestly labeled** — the 4 dev-loop provisioning gaps (credential inheritance, worktree/cwd, GitHub auth, kanban cap) now have architecture constraints (#1417). Hello↔kanban still loose-coupled (#1360 Layer B pending), not misrepresented.
- **Open verification:** #1412 混入 main 后 mac full-suite + canary deploy 已全绿（EOD 确认）。

## §4 Method deltas (Act)

1. **Reinforced — SPEC → codex adversarial review → revise, before build.** The no-tail spec took two review rounds; each found genuine architectural flaws (classifier semantics, ABA-unsafe CAS, quarantine lifecycle, required-sweeper, flip fence). Catching these in the spec saved a broken build. Keep running the loop until SOUND.
2. **Corrected lapse — handoff = self-drive-whole-to-target-branch, not per-phase-PR-merge.** The first no-tail handoff wrongly gated each phase on coordinator review; fixed (#1414) to the recorded convention ([[feedback_phased_handoff_target_branch_no_wait]] / [[feedback_codex_handoff_self_merge_target]]): codex self-drives P0→P3 onto one target branch, coordinator accepts + merges once. The rule was in memory; the lapse was application.
3. **Reinforced — raw `mix test` ≠ acceptance signal in this umbrella.** entity-caps re-verification showed 76/78 "failures" were harness artifacts (UndefinedFunctionError from unloaded sibling apps + SQL-Sandbox ownership); the CI `gate` is the authoritative signal. Reconcile a red re-run against ci.local before blaming the code.
4. **Confirmed-good — honest segmented verification over a faked green.** gaga's #1416 advanced the demo without any raw-RPC/live-DB/priv-esc shortcuts and pinned the real gaps. That's the standard.

## §5 Next (interim — will firm up at EOD)

- **codex: no-tail build** (self-driving `feat/cap-signing-notail-upgrade` P0→P3) → coordinator accepts + merges → canary drain → audit=0 → **lead manual enforce flip** (the security endgame). codex reconciles the #1412 gate overlap on rebase.
- **gaga: W29 demo dev-loop provisioning** (the 4 gaps, per #1417 constraints — GitHub-as-plugin, credential-inheritance split, worktree/cwd-before-sidecar, kanban cap via governance) + **#1405 fault-recovery upper layer** + AgentRuntime ARB-2~5.
- **W29 demo:** close the "agent actually opens a real PR → CI → merge → kanban flow" leg once provisioning lands; gaga tests → allen verifies → ruihua polishes.
- **ruihua:** #1388 DealScout (dating-style two-way match) + #1419 Profile socialware continue.
- **#1403** canary deploy (auth fix, held) — lead times it.
- ✅ #1412 main full-suite + canary deploy 已确认全绿。
