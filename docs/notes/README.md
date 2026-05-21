# Forensic Notes Index

`docs/notes/` is the project's **forensic record**: phase post-mortems, PR
plans, architecture reflections, demo walkthroughs, and planning scratch.
These notes capture *how* and *why* decisions were reached and *what*
actually happened during delivery — they are NOT the normative spec. The
authoritative architecture lives in `../../ARCHITECTURE.md` and
`../../GLOSSARY.md` (Decision Log); phase acceptance criteria live in
`../phase-specs/`. When notes and the normative docs disagree, the
normative docs win.

Six notes have bilingual `.zh_cn.md` companions (marked **[zh]** below).

## Phase forensics / post-mortems

- [Phase 6 — Architecture closeout](phase-6-architecture-closeout.md) — closeout review of Phase 6 architecture work.
- [Phase 6 — Summary](phase6-summary.md) — concise Phase 6 delivery summary.
- [Post-Phase-5 meta-report](post-phase-5-meta-report.md) — 2026-05-17 retrospective on Phase 5 process and outcomes.
- [Phase 7 handoff](phase-7-handoff.md) — Ezagent v1 release handoff (code-complete; demo recording open).
- [Phase 7 resume state](phase-7-resume-state.md) — resume context for the next Claude Code session.
- [Phase 7 / v1-rc1 evidence pack](phase-7-v1-evidence.md) — visual evidence pack for v1-rc1.
- [Phase 8 — branch verification guide](phase-8-deploy-notes.zh_cn.md) — **[zh]** deployment / branch verification notes (Chinese only).
- [Phase 9 Demo — Tenant Isolation (2026-05-21)](phase-9-demo-2026-05-21.md) — **[zh]** tenant-isolation demo writeup.

## Architecture reflections

- [Entity-Agnostic Architecture — Reflection](entity-agnostic-architecture-reflection.md) — reflection on the entity-agnostic design.
- [Workspace = Deployment Unit](workspace-as-deployment-unit.md) — **[zh]** workspace as the unit of deployment.
- [URI Design — current state + open questions](uri-design.md) — **[zh]** URI SPEC design state and the URI normative spec (§5).
- [Plugin Receiver Kind contract](plugin-receiver-kind-contract.md) — the contract for plugins that receive messages from outside ESR.

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

## Archive

- [ARCHITECTURE_GRILL_v0.3.md](archive/ARCHITECTURE_GRILL_v0.3.md) — 2026-05-14 v0.3-era architecture review; historical artifact, superseded by the current `../../ARCHITECTURE.md`.

---

`evidence/` and `phase-9-demo/` subdirectories hold supporting artifacts
(screenshots, recordings, captures) referenced by the notes above.
