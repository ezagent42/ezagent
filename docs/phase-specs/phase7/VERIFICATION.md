# Phase 7 — VERIFICATION

**Status:** LOCKED 2026-05-18 (Allen brainstorm round 3 — V1-V5 buckets approved "基本 OK"; SPEC v3 designed to satisfy these criteria).
**Purpose:** Defines the **observable end-states** that prove Phase 7 is done. SPEC sections exist to produce these outcomes; PLAN.md sequences PRs that close them.

VERIFICATION is the **contract** that lets the implementer (and a future Allen) judge "is Phase 7 complete?" without re-reading the SPEC. If a SPEC item doesn't trace to a V criterion, it's over-engineering. If a V criterion lacks a SPEC item to satisfy it, the SPEC is incomplete.

---

## V1 — New dev productive without Allen

### Success criteria

Each must be observably true with **no Allen involvement**.

1. **5-minute onboarding.** A fresh repo clone + `mix ezagent.bootstrap` produces a running Ezagent (admin LV reachable on http://localhost:4000, CC bridge connected, Feishu sidecar alive) within 5 minutes on a typical dev laptop.
2. **Skill-guided contributions.** When a new dev's Claude Code agent opens any `.ex` file in the Ezagent repo or types `/esr-help`, the `esr-developer` skill activates and supplies:
   - The architectural invariants relevant to that area
   - The anti-patterns it will refuse (with reason)
   - The how-to recipe for the most likely task (add plugin / Kind / Behavior / Template Class / routing rule / invariant test)
3. **Self-service error resolution.** A dev hitting one of the documented common failures (silent drop, orphan sidecar, `:unauthorized` despite cap granted, fork-without-lineage) finds an actionable answer in `docs/runbook/common-failures.md` or the linked forensic note in ≤2 minutes of searching.
4. **Hot plugin install.** A dev writes a minimal plugin in a fresh OTP app, runs `mix ezagent.plugin.install /path/to/plugin`, and observes its Kinds + Behaviors registered + reachable via dispatch — **without restarting phx.server**.

### e2e flow — "first day as new dev"

```
1. git clone ezagent && cd ezagent
2. mix deps.get && mix ezagent.bootstrap
   → EZAGENT_HOME created at ~/.ezagent/default/
   → DB migrated
   → phx.server starts
3. Open http://localhost:4000/admin → admin LV loads (logged in as admin)
4. cd .. && mix new esr_plugin_hello --module EsrPluginHello
   (toy plugin that registers a Kind named "hello" with one action)
5. From ezagent/: mix ezagent.plugin.install ../esr_plugin_hello
   → "✓ Registered: Kind=:hello, Behaviors=[..]"
6. mix esr hello greet --name world
   → "hello, world" (dispatch reaches new Kind, no restart needed)
```

### Gating tests

- `esr_developer_skill_activates_on_repo_open_test.exs` — opening any `.ex` in the repo (via test harness simulating Claude Code skill invocation) returns the esr-developer skill body within 100ms.
- `bootstrap_to_serving_test.exs` — CI runs `mix ezagent.bootstrap` on a fresh checkout + `curl /admin` returns HTTP 302 (auth redirect = LV reachable) within 60s.
- `plugin_hot_install_test.exs` — see V4.

---

## V2 — Multi-agent orchestration production-ready

### Success criteria

1. **Orchestrator stands up a team from natural-language prompt.** Human → @cc-orchestrator "build me a code review team" → orchestrator picks AgentTemplates, calls `add_agent_slot` × N + `write_matcher` × M → 3 worker agents alive and mention-routed within 30 seconds.
2. **Mention routing isolates worker agents.** Human → @backend-dev "what's the file structure" → only backend-dev receives + responds; frontend-dev / reviewer do not get the message (routing rule honors @-mention).
3. **`save_template_as` creates a reusable template.** Orchestrator's `save_template_as("code-review-team")` produces `template://session/code-review-team@<hash>` with `parent_template_uri` pointing at the originating template; the new template is listable via `mix ezagent.session_template.list`.
4. **Re-instantiation produces identical team.** Second human instantiates `template://session/code-review-team:latest` (tag) → new session with the same 3 worker agents + same routing rules. The two sessions can be active concurrently and do not see each other's messages (workspace isolation).
5. **Refinement + version-bump.** Orchestrator in session A calls `update_template()` → new `version_hash` row exists; session A continues on its working copy; session B (instantiated from the new hash) starts with the refined config; older sessions on prior hashes are unaffected.
6. **Persistence survives restart.** Orchestrator adds a slot, phx.server is killed + restarted, the same session restored has the same agent_slot in its working copy.
7. **Error feedback for orchestrator failures.** When orchestrator's `update_template()` is called against a deleted parent hash, the orchestrator surfaces `{:error, :parent_template_deleted}` in the session chat (not silent drop).

### e2e flow — "demo run"

```
1. Human in admin LV → create new session "code-review-test"
   from blank template (entry point 3)
   → session://code-review-test exists with embedded cc-orchestrator agent
2. Human → @cc-orchestrator "I need backend, frontend, and reviewer agents
   for a code review session"
   → orchestrator dialogues; calls:
     - add_agent_slot("backend-dev", template://agent/cc-backend-dev)
     - add_agent_slot("frontend-dev", template://agent/cc-frontend-dev)
     - add_agent_slot("reviewer", template://agent/cc-reviewer)
     - write_matcher(mention("backend-dev") → [agent://...backend-dev])
     - (× 2 more matchers)
   → orchestrator reports back: "Team assembled."
3. Human → @backend-dev "what's in apps/?"
   → backend-dev receives + responds; others do not.
4. Human → @cc-orchestrator "save this as code-review-team"
   → orchestrator calls save_template_as("code-review-team")
   → orchestrator reports: "Saved as template://session/code-review-team@<hash>"
5. From terminal: mix ezagent.session_template.list
   → includes "code-review-team@<hash>"
6. Second human → create new session from template://session/code-review-team:latest
   → fresh session with the same 3 agents.
7. Kill phx; restart; check first session — agent_slot persisted.
```

### Gating tests

- `orchestrator_e2e_demo_test.exs` — scripted version of the flow above (agent-browser + assertion on DB rows for slots, rules, template).
- `template_immutable_hash_test.exs` — `update_template` produces new hash; old hash row unchanged; concurrent sessions on different hashes don't interfere.
- `template_tag_resolution_test.exs` — tagging and re-tagging works as documented.
- `session_persistence_survives_restart_test.exs` — see V4.

---

## V3 — Ezagent v1 delegation model (Phase 7 closes v0 → v1)

### Success criteria

1. **Scope-bounded cap denies out-of-scope grants.** Orchestrator in session A holds `{kind: :session, behavior: :any, instance: {:within_session, A}}`. Its `grant_cap` call targeting a URI in session B (e.g. spawning an agent there, granting cap on an agent in session B) returns `:unauthorized` at CapBAC step 5.5.
2. **Workspace isolation enforced at CapBAC.** Orchestrator's `write_matcher` targeting a different workspace from its own returns `:unauthorized`.
3. **Lineage-bounded cap denies cross-lineage grants.** Orchestrator holds `{kind: :agent, behavior: :any, instance: {:spawned_by, orchestrator_uri}}`. `grant_cap` on an agent NOT in its spawn lineage (e.g. another orchestrator's spawned agent) returns `:unauthorized`.
4. **CLI ↔ LV cap parity.** A non-admin user invoking an action via `mix esr` (token-bound) and the same action via admin LV produces identical authz decisions (granted ↔ granted; denied ↔ denied) for at least 5 sampled action paths.
5. **Feishu inbound preserves error feedback under new cap shapes.** Allen's PR 27 silent-drop fix continues to work — a Feishu user without scope cap for the target session still receives the error text in their Feishu chat + THUMBSDOWN react.
6. **Delegation Decision Log entry.** ARCHITECTURE.md §17.6 contains an entry retiring "v0 不支持 delegation" baseline and documenting the v1 scope-bounded model.

### e2e flow — "scope-bounded cap violation"

```
1. Spawn session://A with orchestrator O_A (scope-bound to session A).
2. Spawn session://B independently (no shared scope).
3. From O_A's tool handler: dispatch grant_cap on agent in session B.
   → expected: {:error, :unauthorized}; audit log writes row with
     authz=denied, reason=:scope_violation.
4. From O_A's tool handler: dispatch grant_cap on agent O_A spawned
   in session A.
   → expected: :ok; audit log writes row with authz=granted.
```

### Gating tests

- `cap_scope_within_session_test.exs` — granted within scope, denied across scope.
- `cap_scope_spawned_by_test.exs` — same as above for lineage.
- `workspace_cap_isolation_test.exs` — write_matcher and other workspace-scoped actions denied across workspaces.
- `cli_lv_cap_parity_test.exs` — table of 5+ action paths × {CLI, LV} → identical authz decisions.
- `feishu_inbound_cap_denial_feedback_test.exs` — PR 27 regression: unauthorized inbound returns Feishu text + react.

---

## V4 — Production-ready foundation

### Success criteria

1. **Repo tree has no DB.** `find . -name "*.db" -not -path "./_build/*" -not -path "./node_modules/*"` returns zero files. CI gate fails on regression.
2. **No v1 prototype references.** `git grep -l "Ezagent.Bridge.V1Prototype" apps/` returns empty. The `apps/ezagent_plugin_cc_bridge_v1_prototype/` directory is deleted. CI gate fails on regression.
3. **Zero orphan sidecar processes.** After `mix phx.server` → `kill -TERM <phx_pid>` → wait 5s, `pgrep -fla "node.*ws_sidecar"` returns nothing (or only sidecars from sibling phx instances).
4. **Workspace isolation in routing.** A routing rule scoped to `workspace://A` is never invoked for messages in `workspace://B`. CI test asserts.
5. **`mix ezagent.bootstrap` one-command setup.** Fresh clone + 1 command → ready-to-serve Ezagent. CI gate runs the bootstrap on a clean checkout.
6. **CC channel v2 is the only path.** All currently-bound agents use `EzagentPluginCc.BridgeRegistry`; the v1 `Ezagent.Bridge.V1Prototype.Server` lookup is unreachable (returns `:error` always — module deleted).
7. **CLI uses per-user token auth.** `mix esr <cmd>` requires `~/.ezagent/<profile>/credentials/cli-token`; admin shortcut only for admin-owned tokens.
8. **Session persistence flip.** `Ezagent.Entity.Session.persistence/0 == {:snapshot, :on_change}`. Pre-Phase-7 ephemeral sessions migrate cleanly (existing snapshot tests pass).

### e2e flow — "fresh laptop production deploy"

```
1. New machine, no Ezagent installed
2. git clone https://github.com/ezagent42/esr-ng.git
3. cd ezagent && mix deps.get
4. mix ezagent.bootstrap
   → EZAGENT_HOME ~/.ezagent/default/{db, credentials, logs, ...} created
   → DB at ~/.ezagent/default/db/ezagent_core_dev.db (not in repo!)
   → CLI token minted at ~/.ezagent/default/credentials/cli-token
   → phx.server starts; admin LV reachable
5. find . -name "*.db" -not -path "./_build/*"
   → (empty — no repo pollution)
6. mix esr session list (using the minted CLI token automatically)
   → ✓
```

### Gating tests

- `repo_root_clean_test.exs` — already exists from Phase 6 PR 1; assert no `*.db` in repo tree.
- `no_v1_bridge_after_cutover_test.exs` — grep apps/ for `Ezagent.Bridge.V1Prototype` returns 0 lines.
- `sidecar_orphan_reap_test.exs` — programmatic spawn + kill phx + assert no orphans.
- `workspace_isolation_test.exs` — routing rule in A doesn't fire for B.
- `bootstrap_to_serving_test.exs` — already listed under V1; same test gates V4.
- `session_persistence_test.exs` — Session slice survives phx restart.

---

## V5 — Drift-resistant architecture (Allen's CI replacement)

### Success criteria

1. **≥8 invariant tests gate Phase 7 principles.** Each test fails the build (not just emits a warning) when its principle is violated. Tests listed under V1-V4 + new ones unique to V5:
   - `workspace_isolation_test.exs` (V4)
   - `orchestrator_cap_scope_test.exs` (V3)
   - `template_immutable_hash_test.exs` (V2)
   - `cap_scope_within_session_test.exs` (V3)
   - `cap_scope_spawned_by_test.exs` (V3)
   - `cli_lv_cap_parity_test.exs` (V3)
   - `no_v1_bridge_after_cutover_test.exs` (V4)
   - `sidecar_orphan_reap_test.exs` (V4)
   - `template_fork_lineage_test.exs` (V2)
   - `repo_root_clean_test.exs` (V4 — already exists, re-enforced)
2. **`esr-developer` skill catches anti-patterns.** When a dev's LLM attempts (in a controlled test harness simulating session prompt):
   - `PubSub.broadcast` bypassing dispatch
   - `:any` atom on cap behavior (should be `:any` only as wildcard, not "behavior shorthand")
   - List/map value in `notifications/claude/channel` meta
   - `:cast` on Feishu inbound dispatch
   - Creating a "generic channel" abstraction covering text + media
   - Trying to make orchestrator deterministic (against D7-1)
   - Trying to include message history in SessionTemplate fork (against D7-7)
   - Trying to support plugin unload in Phase 7 (against D7-8)
   ... the skill returns a refusal with reasoning + pointer to the relevant Decision Log entry.
3. **Every D7-* decision has a numbered Decision Log row.** ARCHITECTURE.md Appendix B contains rows #135 through #144 (one per D7-1..D7-10).
4. **GLOSSARY has all 16 new Phase 7 terms.** (Listed in SPEC §7-4 Decision Log + GLOSSARY + ROADMAP final state section.)
5. **ROADMAP §9b updated with delivery accounting.** Same format as §9 Phase 6 closeout, listing what shipped vs what deferred.
6. **Forensic note `docs/notes/phase-7-handoff.md` exists and declares Ezagent v1 release.**
7. **4 onboarding docs published** at `docs/onboarding/` and `docs/runbook/`.
8. **SPEC_REVIEW 8-item checklist documented** and referenced from CONTRIBUTING.md (or equivalent).

### e2e flow — "dev attempts an anti-pattern"

```
1. New dev opens a Claude Code session in the Ezagent repo
2. esr-developer skill auto-activates (per V1)
3. Dev's LLM proposes:
   "I'll have my new plugin's GenServer subscribe to PubSub topic
   X and write directly to an external HTTP API on message"
4. Skill body section "Anti-patterns the skill refuses" matches
   "naked PubSub.broadcast bypassing dispatch"
5. LLM refuses with reason + cites Decision #127 (Receiver Kind contract)
   + pointer to docs/notes/plugin-receiver-kind-contract.md
6. Dev's LLM proposes the corrected approach (Receiver Kind +
   Behavior + routing_rules)
7. Skill confirms with the how-to recipe.
```

### Gating tests

- `invariant_test_count_test.exs` — `find apps/*/test -name "*invariant*test.exs"` returns ≥8.
- `esr_developer_skill_anti_pattern_table_test.exs` — for each of the 8 anti-patterns above, simulate skill invocation; assert refusal + pointer.
- `decision_log_complete_test.exs` — parse ARCHITECTURE.md Decision Log; assert rows #135-#144 exist with D7-* titles.
- `glossary_phase_7_terms_test.exs` — for each of the 16 GLOSSARY terms, assert section exists.
- `roadmap_phase_6_closeout_format_test.exs` — assert §9b structure matches §9 format.
- `phase_7_handoff_note_exists_test.exs` — `docs/notes/phase-7-handoff.md` exists; first line declares v1.
- `onboarding_docs_test.exs` — 4 doc files exist with non-trivial content (≥600 words each).

---

## Out of scope (deferred — see SPEC Non-goals)

Verifying these is NOT a Phase 7 acceptance criterion. They're either Phase 8+ work or dev-team's call:

- **Federation** (D7-4)
- **Plugin unload / swap** (D7-8)
- **Production OTP release / Docker / systemd** (D7-9)
- **SessionTemplate three-way merge** (D7-7)
- **Template synthesis** (orchestrator authoring AgentTemplates inline)
- **Cross-session agent delegation**
- **Multimedia / streaming** (Phase 8 — see ROADMAP §9c)
- **Multi-agent on a single macOS user without `apiKeyHelper`** — fundamental Keychain limitation; documented in runbook, not solved
- **Load testing / performance optimization** — "works for small team" is sufficient

---

## Sign-off

- [x] Allen approves V1-V5 buckets (round 3 — "基本 OK")
- [ ] PLAN.md sequences PRs to close each V
- [ ] DECISIONS.md initialized for implementation-time judgment calls
- [ ] All gating tests above are present and passing in CI before Phase 7 closes
- [ ] Forensic note `docs/notes/phase-7-handoff.md` declares Ezagent v1 release
