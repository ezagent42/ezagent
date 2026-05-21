# Phase 7 — PLAN

**Status:** LOCKED 2026-05-18 (derived from SPEC v3 + VERIFICATION).
**Purpose:** Sequencing of PRs to deliver Phase 7. Each PR is gated by:
1. Pre-implementation SPEC review (subagent — per `feedback_subagent_review_plans`)
2. Implementation + tests
3. SPEC_REVIEW checklist (the 8-item one from SPEC §SPEC_REVIEW walkthrough)
4. Subagent re-review against actual code post-implementation
5. Push, open PR, admin-merge

Total estimate: **~24 PRs**, 12-15 days autonomous execution.

---

## Dependency graph

```
                       ┌────────────────────┐
                       │  Pre-7  SPEC v3 +  │
                       │  VERIFICATION +    │
                       │  PLAN +            │  (PR 30 — already drafted, locking now)
                       │  DECISIONS         │
                       └─────────┬──────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              ▼                                     ▼
       ┌──────────────┐                      ┌────────────┐
       │   7-1 Infra   │                      │   docs    │
       │   closeout    │                      │   stream  │
       │   (6 PRs)     │                      │   7-4 docs│
       └──────┬───────┘                      │   can     │
              │                              │   start   │
              ▼                              │   in      │
       ┌──────────────┐                      │   parallel│
       │ 7-2 Templates │                      └─────┬──────┘
       │   (5 PRs)    │                            │
       └──────┬───────┘                            │
              │                                     │
              ▼                                     │
       ┌──────────────┐                            │
       │  7-3         │                            │
       │  Orchestrator│                            │
       │  (8 PRs)     │                            │
       └──────┬───────┘                            │
              │                                     │
              └─────────────────┬──────────────────┘
                                ▼
                       ┌──────────────┐
                       │  7-4 Handoff │
                       │  closeout    │
                       │   (5 PRs)    │
                       └──────────────┘
```

**Parallelizable:** 7-4 Ezagent skill content + onboarding docs writing can ramp during 7-1/7-2/7-3 (writers don't block on code). The 6+ invariant tests of 7-4 close LAST because they depend on 7-1/7-2/7-3 features.

---

## PR sequence (~24 PRs)

Each row: number, title, sub-step, est. effort (S/M/L), V criteria closed, dependencies.

### 7-1 Infra closeout (6 PRs, ~3-4 days)

| # | Title | Effort | V criteria | Deps |
|---|---|---|---|---|
| 31 | feat(routing): enforce workspace_uri across all matcher invocations + invariant test | S | V3.2, V4.4 | — |
| 32 | refactor(cc-channel): full v1→v2 cutover + delete v1 prototype app + grep invariant | L (large blast radius) | V4.2, V4.6 | 31 |
| 33 | feat(mix): `mix ezagent.bootstrap` one-command setup | S | V1.1, V4.5 | — (parallel to 31) |
| 34 | feat(identity): per-user CLI bearer token + LV mint UI + parity invariant | M | V3.4, V4.7 | 31 |
| 35 | fix(feishu): ws_sidecar EOF→exit handler + orphan reap invariant | S | V4.3 | — |
| 36 | feat(mix): `mix ezagent.plugin.install` runtime hot-load + invariant | M | V1.4, V4.* | 35 (just to avoid sidecar contention in tests) |

**7-1 closeout PR**: combined progress report + manual smoke test of the 6 PRs together. No code; Feishu update only.

### 7-2 Templates (5 PRs, ~3 days)

| # | Title | Effort | V criteria | Deps |
|---|---|---|---|---|
| 37 | feat(domain): Ezagent.Entity.AgentTemplate Kind + slice + LV creation form + mix task | M | V2.* prerequisites | 32 (v2 cutover for `cc-orchestrator` template) |
| 38 | feat(domain): Ezagent.Entity.SessionTemplate Kind + git-style hash versioning + tag registry | L | V2.3, V2.5, D7-10 | 37 |
| 39 | feat(identity): template:read / template:write / template:instantiate cap kinds + parser + Identity Behavior integration | M | V3.1, V3.6 | 38 |
| 40 | feat(domain): Ezagent.Entity.Agent.spawn/4 + Agent slice workspace_uri + spawned_by fields + migration | M | V3.3, V2.4 | 37 |
| 41 | feat(domain): Ezagent.Entity.Session.spawn_from_template/2 (the Generator) + CapBAC gate | M | V2.1, V2.4 | 38, 39, 40 |

**7-2 closeout PR**: progress report.

### 7-3 Orchestrator (8 PRs, ~4-5 days)

| # | Title | Effort | V criteria | Deps |
|---|---|---|---|---|
| 42 | feat(core): Capability.matches?/2 tuple-shape extension ({:within_session, _}, {:spawned_by, _}) | M | V3.1, V3.3 | — |
| 43 | feat(core): dispatch ctx :session_uri enrichment (derive from target URI) | S | V3.1 | 42 |
| 44 | feat(domain): Session slice template_working_copy field + persistence flip (:ephemeral → :on_change) + migration | M | V2.6 | 41 |
| 45 | feat(domain): cc-orchestrator AgentTemplate seed + dev-profile boot install | S | V2.1 | 37 |
| 46 | feat(orchestrator): 7 MCP tools (add_agent_slot / remove_agent_slot / update_agent_template / write_matcher / update_template / save_template_as / list_templates) + tool handlers dispatch via Ezagent.Invocation | L | V2.1, V2.5 | 44, 45 |
| 47 | feat(orchestrator): Generator grants scoped delegation caps to spawned orchestrator at instantiate time | S | V3.1, V3.3 | 41, 42, 43 |
| 48 | fix(orchestrator): in-flight template-deletion semantics (return :parent_template_deleted from update_template; save_template_as still works) | S | V2.7 | 46 |
| 49 | test(orchestrator): full e2e demo flow + agent-browser screenshots + invariant gates | M | V2.* (all), V5.1 | 46, 47, 48 |

**7-3 closeout PR**: progress report + e2e demo screenshots.

### 7-4 Handoff readiness (5 PRs, ~2-3 days)

| # | Title | Effort | V criteria | Deps |
|---|---|---|---|---|
| 50 | docs(skill): .claude/skills/esr-developer/SKILL.md + bundle (architectural invariants, anti-patterns, how-to recipes, debug recipes, conventions, pointer index) | M | V1.2, V5.2 | 49 (orchestrator pattern stable) |
| 51 | docs(onboarding): 4 docs — first-30-days, adding-a-plugin, adding-kind-behavior-template, common-failures runbook | M | V1.3, V5.7 | 50 (skill content informs docs) |
| 52 | test(invariants): add the 8+ Phase 7 invariant tests (those NOT already added inline with 7-1/7-2/7-3 PRs) | M | V5.1 | all prior |
| 53 | docs(arch): Decision Log #135-#144 + GLOSSARY 16 terms + ROADMAP §9b delivery accounting + ARCHITECTURE §7.3/§7.5/§17.6 v1 delegation updates | M | V3.6, V5.3, V5.4, V5.5 | all prior |
| 54 | docs(forensic): docs/notes/phase-7-handoff.md (full closeout record + Ezagent v1 release declaration) + CONTRIBUTING.md SPEC_REVIEW checklist | S | V5.6, V5.8 | 53 |

**Phase 7 closeout PR**: final progress report + tagged release `v1.0.0`.

---

## Per-PR workflow (autonomous)

```
For each PR N in [31..54]:

  1. Read SPEC + VERIFICATION rows this PR closes
  2. Spawn fresh branch off origin/main
     (rebase if main moved since last PR)
  3. Subagent-review (Explore): "What existing code does this
     PR touch? Any architectural assumptions in adjacent
     modules I'd violate? Any hidden coupling?"
  4. Implement per SPEC row's "Detail" field
  5. Write tests gating the row's "Acceptance" field
  6. mix compile + mix test (target affected app subset)
  7. Self-run SPEC_REVIEW 8-item checklist; document in PR body
  8. Subagent re-review against new code: "Does this match SPEC?
     Any drift introduced? Any obvious gaps Allen would catch?"
  9. git commit + push + gh pr create
  10. gh pr merge --admin --squash --delete-branch
  11. Update docs/phase-specs/phase7/PLAN.md to mark PR done
  12. If decision point hit (architecture surprise / SPEC ambiguity):
      - Feishu progress report with question
      - Block on Allen response unless trivially resolvable
```

---

## Risk register

| Risk | Mitigation |
|---|---|
| 7-3 PR 42 (Capability.matches?/2 tuple extension) introduces regression in existing CapBAC paths | Audit ALL existing `matches?/2` call sites in PR; ensure default behavior when ctx fields absent is "no scope = match anything not scope-tuple"; add regression test for each existing site |
| 7-1 PR 32 (CC v2 cutover) breaks live dev environment (Allen's `agent://cc-demo`) | Manual e2e test with agent-browser screenshot before push; have Phase 6 v1_prototype branch ready to revert if v2 swap fails; do this PR during a time Allen would notice quickly if regressed (early-batch) |
| Orchestrator's CC instance + Ezagent's CC bridge contend on credentials | Use existing operator `~/.claude/` for dev; per Allen "用当前 h2oslabs 的 cc 登录凭证"; per-agent isolation deferred to Phase 8+ if needed |
| SessionTemplate hash determinism issue across BEAM runs | Use `:erlang.term_to_binary(slice, [:deterministic])` per SPEC D7-10; CI test that re-hashing identical content produces identical hash |
| 7-3 e2e demo flaky (LLM orchestrator non-deterministic) | Use sandboxed CC instance with controlled prompt; assert structural outcomes (DB rows exist, agents bound) not exact LLM text |
| AFK timing: a PR fails subagent review, I make wrong fix, ship broken code | Each PR's subagent re-review is the gate; if review flags issues, I fix AND re-review before push; never push on a "✗ Wrong" finding without addressing it |
| Some V criterion has no PR mapped (verification gap) | After 7-3 closes, do a coverage audit: walk every V success criterion, ensure a test or doc closes it; add catch-up PRs to 7-4 if gaps |

---

## Progress report cadence

To Allen via Feishu:

- **Sub-step boundaries** (4 reports + closeout): "7-1 done (25%)", "7-2 done (50%)", "7-3 done (75%)", "7-4 done (100%)"
- **Decision points** (any time): scope cut, architecture surprise, SPEC ambiguity needing his call
- **Stuck** (any time): test repeatedly fails or design refuses to settle

Format per `feedback_progress_percentage_in_replies`: lead with `[N% — sub-step X done]`.

---

## Sign-off

- [x] PLAN derived from SPEC v3 + VERIFICATION
- [ ] PLAN merged with SPEC + VERIFICATION as one PR (PR 30 amended)
- [ ] First sub-step (7-1) PR sequence begins
