# Review — weekend 2026-06-26 → 2026-06-28 (Fri–Sun)

**Lead:** Claude (coordinator)  ·  **Repo:** ezagent42/ezagent  ·  **main tip:** `299b6462`

This covers the weekend burst (Fri 0626 → Sun 0628). All work merged directly to `main` via `--admin --squash --delete-branch` after per-PR verification (no stack.md/returns this cycle — direct-merge cadence).

## 1. What landed (40 PRs merged, 0626→0628)

### Architecture / socialware 收口 (the weekend's theme)
- **#1069** socialware P1-P10 — base/socialware/fixture model + codex-orchestrator + P10 E2E gate (codex self-drove; independent review SOUND, CI clean). The unified socialware model lands.
- **#1068** socialware SPEC + P1-P10 codex handoff (docs).
- **#1072** taxonomy/boundaries SPEC — 4 carrier layers (code plugin / definition data / runtime state+blob / EZAGENT_HOME) + judgment rule + verified anti-patterns + red lines.
- **#1074** GLOSSARY + ARCHITECTURE + three-tier aligned to unified model; §10.5 inline-BLOB red-line-violating doc rewritten → landed Uploads+FsResolver+DownloadToken.
- **#1070** A→Recipe symbol rename (`Ezagent.Role`→`Ezagent.Agent.Recipe`) (#127).
- **#1071** recipe ConfigStore storage key `role`→`recipe` (pre-prod; closes #127 deferred OQ). **role 收口 done**: recipe (code+storage) unified; "role" word = responsibility meaning only.
- **#1075** kanban 9-stage business-semantics de-bake (code→recipe data; taxonomy §4.1 leak closed).
- **#1076** Q1-C full plugin-package — manifest + hot-load (no restart) + assets hot-load (#1065-class fix) + unload/swap (closes D7-8) + codex-runnable E2E gate. Independent review caught + fixed **H-1 path-traversal security** (public `/plugin-assets/` endpoint could exfiltrate EZAGENT_HOME creds via malicious manifest `file`), H-2 silent no-op, M-4 debug code.
- **#1059** recipe/responsibility decouple lock-in (T1-T3 + no-default) — the semantic split that made the rename safe.
- **#1048** role-as-data (roles as ConfigObjects, read-through, idempotent seed).
- **#1047** comms-unify PR-1+2 (codex) — collapse chat+external feeds onto one SessionFeedChannel.
- **#1060** comms MED anti-regression gates.

### Bug fixes (latent + deploy-blocking)
- **#1066** cc ReadyGate via bridge-bind (#505) — **regular cc agents never became ready before** (only orchestrator cc did; latent bug unmasked by the socialware work).
- **#1064** cold-restart role-seed collision (atom-valued requested_caps JSON asymmetry) — **boot-crash on restart against a seeded DB** (deploy-#110-relevant).
- **#1062** Dockerfile.prod+Dockerfile.ci empty-proxy build break (#129).
- **#1061** Dockerfile.dev image build (exqlite NIF + npm ERESOLVE) (#124).
- **#1065** hello plugin island build in shared aliases (#1063).
- **#1055** eliminate the #108 CI flakes (harness-verified).
- **#1054** orchestrator role bootstrap DB read-through ownership (#1048 regression).
- **#1052** positional URI read in role_registry workspace_host (uri_query gate).
- **#1056** autosvc Tier-1 seed RoleRegistry rename regression.
- **#1041** unmask silent Loader OwnershipError + required_caps parity (#108).
- **#1049** CR governance publish-status gate + non-user-layer materialization.

### Features / E2E
- **#1057** F7 PR-B spawned-worker teardown + owner teardown cap.
- **#1046** F7 PR-A remove_participant (user/invited, isomorphic, owner-gated).
- **#1051** AutoService Tier-1 seed + deterministic regression (scenario-13).
- **#1050** container-reachable chromium sidecar for in-container E2E browser.
- **#1045** local ubuntu-CI docker harness (reproduces macOS-impossible flake).
- **#1042** minimal CR governance (stage→preview→publish on ConfigStore).
- **#1039** unified non-activating Domain.Agent.read_* + no_surface_read_dispatch gate.
- **#1037** retire the customer concept → anon-user + external visibility.
- **#1036** retrieval-first KB (kb role × native, sqlite FTS5 trigram).
- **#1038** rename default key advisor.behavior → agent.soul.
- **#1053** LLM Protocol API rename + endpoint module split.

### Docs / process
- **#1067** autoservice flavor-agnostic reframe + final no-shared-loop decision (shelves #133 agentic-loop; autosvc = chat fixture).
- **#1073** Q1-C codex handoff doc.
- **#1058** weekend session process + efficiency record.
- **#1044/#1043** autoservice e2e scenario + v3 reference.
- **#1040** merge agent-extension guidance into ezagent-developer skill.

## 2. Efficiency stats

- **40 PRs merged** in ~3 days (0626→0628). Of these, ~24 in the 0627 burst, ~14 on 0628 (the socialware 收口 day).
- **Cadence**: direct-merge after per-PR verification (independent adversarial review on the 3 biggest: #1069 socialware, #1076 Q1-C, #1066 cc-readygate). No stack.md/returns this cycle — lead merged each PR as gates passed.
- **Subagent pattern**: opus subagents for investigation (autosvc reframe, socialware operator/template-model analysis, taxonomy) + implementation (socialware P1-P10 codex-style, kanban de-bake, Q1-C, glossary/arch). Codex-CLI available but opus subagents used for controllability (monitor + re-dispatch on stall). 3 transient API stalls recovered via commit-per-step + fresh re-dispatch.
- **Independent review ROI**: the #1076 review caught a **security-critical path-traversal** (H-1) the author missed — the public `/plugin-assets/` endpoint would've leaked credentials. This vindicates the "independent adversarial review on big/risky PRs" discipline.
- **Parallel tracks**: up to 3 subagents concurrent (glossary/arch + kanban leak + Q1-C on 0628).

## 3. Gaps / deferrals

- **#108 flake-hardening** (PluginIsolation/AnonUserGC deep races) — still in_progress; the recurring flakes were note-only all weekend. Tracked.
- **#110 live three-env deploy** — fully unblocked (images build, cold-restart fixed, cc ready, hello island) but **not done** — needs Allen's hands for the live promotion.
- **#111 deploy-flow skill** — after #110.
- **#1020 kanban e2e** — deferred (Allen: revisit after socialware lands; now landed).
- **#127 A→Recipe storage-key rename** — DONE (#1071).
- **#128 F7-PR-B hardening** — deferred.
- **#88 inbound email** / **#55 doc coverage** / **#112 OS sandbox** — long-term.
- **Q1-C follow-ups**: M-3 install rollback on partial failure; M-5 same-module hot-reload E2E; L-6/L-7 concurrent unload+re-register race; `Ci` module deeper de-bake (ci-criteria + labels still in code, #144 OQ).
- **Glossary/arch**: Decision Log #155 entry + full arch-doc alignment — #1074 did the bulk; deeper historical-section refresh is follow-up.

## 4. Next-period planning suggestions

- The weekend was **architecture 收口** (socialware unified, taxonomy, plugin-package). This week pivots to **product/launch** (官网上线 + 内测 + 自举).
- **Carry-in for the week**: #110 live deploy (unblocked), #1020 kanban e2e review (post-socialware), the Q1-C follow-ups (esp. live agent-browser E2E as secondary confirmation of the plugin-package).
- **Process tweak**: for big/risky PRs (#1069/#1076-class), the independent adversarial review is now standing practice (it caught the security bug). Keep it. For doc-only PRs, skip it (overhead).
- **Method**: the codex-handoff contract (self-merge to ONE target branch + pre-set goal self-drive + return for lead accept+merge) worked well for socialware P1-P10 + Q1-C — keep as the default for large implementer dispatches.

## 5. Method deltas (MANDATORY)

- **codex-handoff self-merge contract** → saved as `feedback_codex_handoff_self_merge_target` memory: codex/subagent self-merges onto ONE target branch (base main), does NOT merge to main / open PR, returns target branch; lead pre-sets a goal + per-phase gates; lead accepts+merges. **Promoted to standing practice** (used for socialware P1-P10, #127, #1071, Q1-C).
- **Independent adversarial review on big/risky PRs** → the #1076 path-traversal catch vindicates this. **Rule**: any PR touching (a) public/unauthenticated endpoints, (b) BEAM code-purge/unload, (c) file-serving paths, or (d) >300 lines of core machinery gets an independent opus review before merge. Mapped to the existing `feedback_admin_merge_verify_every_failure` + `feedback_subagent_review_plans`.
- **"Known-flake" name is not a free pass** (AgentReadTest lesson, reinforced): #1069's only CI red was PresenceReadReceipts — verified it also fails on main (not a regression) before merging. The discipline held all weekend (no flake-masked regression slipped).
- **Process debt**: the direct-merge cadence (no stack.md/returns) worked for a solo-coordinator weekend but **doesn't exercise the dev-together stack/return/reconcile loop**. If more team members return handoffs this week, re-engage the stack.md flow. Tracked as process-debt (owner: lead).

## 6. Roster

Solo-coordinator weekend (Claude as lead+implementer-via-subagents; Allen reviewing via Feishu). `docs/together/team.md` current_track update deferred to the week's first plan (Allen is re-scoping to 官网/内测/自举 this week — a pivot from the architecture track).

## Required accounting

| Metric | Count |
|---|---|
| Planned tasks (weekend) | ~15 (the 6-item checklist + architecture reframes) |
| PRs merged to main | 40 |
| Independent adversarial reviews run | 3 (#1069, #1076, #1066) |
| Reviews that caught must-fix issues | 1 (#1076: H-1 security + H-2 + M-4) |
| Subagent stalls (transient API) recovered | 3 |
| Deferrals carried forward | #108, #110, #111, #1020, #128, #88, #55, #112, Q1-C follow-ups |
| Flake-masked regressions slipped to main | 0 |
