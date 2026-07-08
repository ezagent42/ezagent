# Forensic Notes Index

`docs/notes/` is the project's **forensic record**: phase post-mortems, PR
plans, architecture reflections, demo walkthroughs, and planning scratch.
These notes capture *how* and *why* decisions were reached and *what*
actually happened during delivery — they are NOT the normative spec. The
authoritative architecture lives in `../../ARCHITECTURE.md` and
`../../GLOSSARY.md` (Decision Log); phase acceptance criteria live in
`../phase-specs/`. When notes and the normative docs disagree, the
normative docs win.

Seven notes have bilingual `.zh_cn.md` companions (marked **[zh]** below).

## Phase forensics / post-mortems

- [Phase 6 — Architecture closeout](phase-6-architecture-closeout.md) — closeout review of Phase 6 architecture work.
- [Phase 6 — Summary](phase6-summary.md) — concise Phase 6 delivery summary.
- [Post-Phase-5 meta-report](post-phase-5-meta-report.md) — 2026-05-17 retrospective on Phase 5 process and outcomes.
- [Phase 7 implementation audit (2026-05-22)](phase-7-implementation-audit-2026-05-22.md) — honest as-built audit: Phase 7 was ~55-60% real; the basis for the completion effort. **(also [zh](phase-7-implementation-audit-2026-05-22.zh_cn.md))**
- [Phase 7 handoff](phase-7-handoff.md) — corrected handoff; the original 2026-05-18 "v1 release, code-complete" claim was premature and is corrected (Phase 7 completed 2026-05-23 by the 6-PR completion effort).
- [Phase 7 resume state](phase-7-resume-state.md) — **superseded** by the audit + completion SPEC; kept for historical record only.
- [Phase 7 / v1-rc1 evidence pack](phase-7-v1-evidence.md) — visual evidence pack for v1-rc1.
- [Phase 8 — branch verification guide](phase-8-deploy-notes.zh_cn.md) — **[zh]** deployment / branch verification notes (Chinese only).
- [Phase 9 Demo — Tenant Isolation (2026-05-21)](phase-9-demo-2026-05-21.md) — **[zh]** tenant-isolation demo writeup.

## Architecture reflections

- [Entity-Agnostic Architecture — Reflection](entity-agnostic-architecture-reflection.md) — reflection on the entity-agnostic design.
- [Workspace = Deployment Unit](workspace-as-deployment-unit.md) — **[zh]** workspace as the unit of deployment.
- [URI Design — current state + open questions](uri-design.md) — **[zh]** URI SPEC design state and the URI normative spec (§5).
- [Plugin Receiver Kind contract](plugin-receiver-kind-contract.md) — the contract for plugins that receive messages from outside Ezagent.
- [Lifecycle persistence-access discipline (2026-06-03)](2026-06-03-lifecycle-persistence-discipline.md) — persistence + create/activate go through the Lifecycle/framework functions, not low-level primitives; scan result (already clean) + the enforcing lint + follow-ups (maybe_save / SnapshotStore.write test-only writers).
- [`home_path_in_runtime_code` scan gate ↔ #25 `raw_home_path` reconciliation (2026-06-08)](2026-06-08-home-path-scan-reconciliation.md) — Resource-unification P0.5: why two scanners (arch.scan count ratchet vs uri_query.scan hard-fail-new), the consistency test that keeps them from drifting, the baseline+exemption census on current main, and the codex exemption-robustness findings folded in.
- [Documentation coverage audit + enforcement gate (2026-06-13)](doc-coverage-audit.md) — `@moduledoc`/`@doc` coverage (98.8% modules, 72.4% non-`@impl` public-fn) + WHY-vs-restates quality tally; calibration baseline + ratchet for the new `mix ezagent.doc.scan` gate.
- [Socialware 基座化 live E2E validation (2026-06-15)](2026-06-15-socialware-substrate-live-e2e-validation.md) — closes #63's live tier: the im→session→agent refactor validated end-to-end on the disposable stack (orchestrator readiness + session→agent transport + cc reply roundtrip, 3/3); the bug it fixed (#783) + the 3 disposable-stack/#17 provisioning gaps it surfaced (admin-caps non-bug, per-agent claude login, Feishu caller-open_id) — all orthogonal to the refactor.
- [Live orchestrator MCP-registration deadlock (2026-06-15)](2026-06-15-live-orchestrator-mcp-registration-bug.md) — fresh-stack E2E finding: the durable session→orchestrator binding was written at step 6, AFTER the step-5 readiness gate that the live MCP join (self-registering via `McpServer` lazy rebuild) needs — so every join was rejected `:orchestrator_not_registered` → 90s timeout → create rollback. Fix pre-persists the deterministic planned URI before the gate; deterministic tests masked it (test-mode signals readiness without a live join).
- [CapBAC system-principal audit — "No unowned permissions" (2026-06-16)](2026-06-16-capbac-system-principal-audit.md) — GLOSSARY Decision #154: every cap's `granted_by` must be a real entity; abstract `system://…` principals that MINT permissions (hold `grant_cap`/`revoke_cap`) are "unowned". A/B classification of all 15 Catalog principals (8 A / 1 confirmed-B `template-materialize` / 6 needs-Allen, of which agent-internal + feishu-binding-policy are strong-B-lean minters). Backs the ratchet gate `no_unowned_system_principal_grant_test.exs`; conversions (#811 cap#2, #808 anon-access) shrink the allowlist → 0.
- [Keep the bespoke `ezagent_core` framework — Ash / actor-framework ROI (2026-06-20)](2026-06-20-bespoke-core-framework-roi-decision.md) — **[zh]** Allen-decided: keep the in-house Kind/Behavior actor runtime (~37.6K, ~30%) on raw OTP rather than migrate. Four studies: code composition (auth ~7% but pervasive), size benchmark (healthy/lean — app layer ~88K is in-band; the framework is the "looks big" factor), Ash-ROI (Ash is declarative-data not actor; snapshots are `term_to_binary` blobs = Ash-hostile; ~3-5K addressable, negative ROI), actor-framework survey (primitives already OTP; no lib replaces the abstraction; Commanded is rewrite-not-migration + its wins are already in-house via `event_log`/`saga_runner`). Greenfield-only Ash for new relational/authz; Horde only for multi-node.

## Walkthroughs / demos

- [curl-agent plugin walkthrough](curl-agent-walkthrough.md) — DeepSeek backend, per-user API keys.
- [Demo follow-up walkthrough](demo-followup-walkthrough.md) — agent config UI + PTY + routing + multi-agent.
- [PR 49 — orchestrator e2e demo recording](pr49-e2e-demo.md) — orchestrator end-to-end demo recording notes.

## PR plans

- [PR #142 — Entity-agnostic three-piece](pr-142-plan.md) — S-1, S-2, S-3 entity-agnostic work.
- [PR #143 — Feishu re-shape](pr-143-plan.md) — delete the `feishu://` scheme.
- [PR #144 — Dissolve synthetic singletons](pr-144-plan.md) — remove `routing-admin://` and `pty-input://`.
- [PR #145 — `@known_schemes` runtime ETS](pr-145-plan.md) — `parse!/1` lockdown.
- [PR #146 — Query-string action syntax](pr-146-plan.md) — `/behavior/X/Y` → `?action=X.Y`.
- [PR #147 — Polish + registry removal](pr-147-plan.md) — AgentTypeRegistry removal + `Message.uri` → `Message.id`.

## Planning notes

- [Phase 1b — Channel Server Plan](phase1b-channel-plan.md) — channel server plan (revised after channels-reference recon).
- [SPEC review checklist](spec-review-checklist.md) — checklist for reviewing phase SPEC documents.
- [ezagent Web Admin — Static HTML Prototype Brief](prototype-design-prompt.md) — **[zh]** prototype design brief for the Web Admin.
- [ezagent Web Admin — IDE-shell Prototype Brief](prototype-design-prompt.ide-shell.zh_cn.md) — **[zh]** IDE-shell variant of the Web Admin prototype brief.
- [Grill report — IDE-shell prototype brief](prototype-design-prompt.ide-shell.grill.md) — grill review of the IDE-shell prototype brief.
- [Frontend: replace LiveView so admin becomes "a socialware"? (2026-06-19)](2026-06-19-frontend-socialware-unification-research.md) — research: thesis does NOT hold (rev8 dual-surface already decided admin=LiveView, customer=React+json-render); json-render is display-only (can't express admin UI); `/api/v1`+`lv_cli_parity` is the real UI-agnostic contract; if any JS, React-SPA not Next.js; loom investment belongs on the agent-generated customer surface.

## Design research

- [Skill distribution to deployed agents (2026-07-08)](skill-distribution-design.md) — **[zh]** how agent SKILLS reach deployed agents, governed by the **recipe** layer (Allen: "由 recipe 去管理"). Root cause: `mix release` packages only `priv/`, so the repo-root `.claude/skills/` walk-up in `OrchestratorBootstrap` finds nothing in a release image → session-create dead on every channel. Maps the (already-landed) `Recipe.skills` declaration + `RecipeRegistry`/`ConfigStore` three/four-state seed contract + np-uv and socialware `$EZAGENT_HOME` reference models; the gap is a skill **content backend** (the `SkillRegistry` mirror of `RecipeRegistry`). Recommends **hybrid** (bundled `priv/` defaults + `$EZAGENT_HOME` overlay, content-hash reconcile) over pure-store (reintroduces the incident) or pure-bundle (no post-deploy add); phased migration (P1 retires the point-fix + generic resolver + runtime-vs-dev skill subset; P2 overlay+seed; P3 walk-up dies). Pushes back on async materialization (skill copy is KB text — sync, folded into `HomeRuntime.stage_and_swap`).

## Stress / capacity tests

- [V1 stress-test results (2026-05-22)](v1-stress-test-results-2026-05-22.md) — **[zh]** measured answers to the agents-per-session / max-sessions / max-users questions at a Raspberry-Pi (`+S 4:4`, ~4 GB) resource profile; which bottleneck bit first.

- [CI flake reproduced on ubuntu-docker (2026-06-27)](2026-06-27-ci-flake-docker-repro.md) — the `make ci.repro` harness reproduced the macOS-impossible CI flakes (`AgentReadTest`, `DefaultSessionTemplateSeedTest`) on the FIRST iteration at seed 979933 (green on darwin, red on the runner); validates `ci-flake-diagnosis.md`.

## Archive

- [ARCHITECTURE_GRILL_v0.3.md](archive/ARCHITECTURE_GRILL_v0.3.md) — 2026-05-14 v0.3-era architecture review; historical artifact, superseded by the current `../../ARCHITECTURE.md`.

## Retired specs

- **`2026-05-22-cc-agent-config.md`** — retired 2026-05-23. Drafted on branch `docs/cc-agent-config-spec` (deleted, never merged). Its `CLAUDE_CONFIG_DIR` sandbox / `settings_path` / `mcp_config_path` / `api_key_helper` design was absorbed by `Ezagent.Entity.AgentTemplate` (Phase 7) and is now the authoritative source. The operational guidance (macOS Keychain caveat + credential-seeding question) survives in [`../runbook/cc-agent-config.md`](../runbook/cc-agent-config.md). See Phase-7 completion SPEC §3 "cc-agent-config reconciliation" for the decision rationale.

---

`evidence/` and `phase-9-demo/` subdirectories hold supporting artifacts
(screenshots, recordings, captures) referenced by the notes above.
