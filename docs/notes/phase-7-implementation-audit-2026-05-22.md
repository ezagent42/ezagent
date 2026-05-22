# Phase 7 implementation audit — designed vs shipped (2026-05-22)

> **Audit type:** READ-ONLY. No code changed. This note is the only artefact.
> **Trigger:** Allen Feishu 2026-05-22 — "做 phase 7 审计，看起来 phase 7 很多没完成."
> **Method:** Read the actual code (not grep-counts). Each Phase-7 element
> classified IMPLEMENTED / STUB / PARTIAL / ABSENT against
> `docs/phase-specs/phase7/SPEC.md` (LOCKED v3) + `VERIFICATION.md` (V1-V5).

## Why this audit exists — the resume-state contradiction

`docs/notes/phase-7-resume-state.md` is **internally contradictory and
cannot be trusted**:

- Its header says *"Phase 7 at v1 release. Code-complete"* and lists PRs
  #118/#119/#120 merged ("#119 = PR 46-impl — 7 orchestrator tool bodies
  wired").
- Its own status **table** simultaneously shows PR 46/47/48/49/52 as ⏳
  pending and the summary rows say "7-2 templates ⏳", "7-3 orchestrator
  ⏳", "7-4 handoff ⏳".

The truth (from reading the code, 2026-05-22) sits between the two: the
**module skeletons all exist and several pieces are genuinely complete**,
but the **headline feature — a running Orchestrator that turns a
SessionTemplate into a live team — does not work end to end.** Several
"merged" PRs landed *surface declarations + structural tests* rather than
working behaviour.

Note also: the repo has moved well past Phase 7 (now on Phase 8 / Phase 9
— mention-gated routing, tenant isolation, nested-shell UI). Phase-7
gaps were carried forward unfinished, not closed.

---

## Status table — each Phase-7 element

| # | Element | Status | Evidence |
|---|---------|--------|----------|
| 1 | **WorkspaceRegistry** (5th ETS registry) | **IMPLEMENTED** | `apps/ezagent_core/lib/ezagent/workspace_registry.ex` — full `bind/unbind/lookup/list_all/default_workspace_uri`. Real ETS table. Demoted to a "consistency cache" in Phase 9 PR-7 (workspace now derived structurally from the URI), but the registry itself is complete and used. |
| 2 | **AgentTemplate Kind + `template://` scheme** | **PARTIAL** | `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex` — Kind contract exists (`type_name/behaviors/persistence/supervisor`) and `template://` host dispatch is wired in `ezagent_domain_chat/application.ex:404` (`"agent"` → AgentTemplate). **But:** it does NOT implement the `Ezagent.Kind.Template` behaviour (`template_name/0` / `validate/1` / `instantiate/3`) that SPEC §D7-2 requires; the slice schema is documented in the moduledoc only — there is no slice-field code, no validation, no `instantiate/3`. It is a bare Kind, not a Template Class. |
| 3 | **SessionTemplate Kind + SHA-256 versioning** | **PARTIAL** | `apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex` — Kind contract + `compute_version_hash/1` (real SHA-256, `:erlang.term_to_binary(_, [:deterministic])`, drops timestamps) + `build_uri/3`. Tests `session_template_test.exs` (9 pass per resume-state). **But:** no `Ezagent.Kind.Template` behaviour impl, no `instantiate/3`, no slice fields, **no `fork/2`, no `create/2`** (SPEC §"Session-creation entry points" requires both). `parent_template_uri` / `version_tag` / `template_tags` registry exist only as moduledoc prose. **No `template_tags` registry module exists at all.** |
| 4 | **template caps** (`template:read/write/instantiate`) | **PARTIAL** | `apps/ezagent_core/test/ezagent/template_caps_test.exs` (12 tests) pins the *semantic partition* — cap kinds are open atoms so they "work" structurally. **But:** no code path actually *checks* a `template:` cap. `template:instantiate` has zero call sites (grep of `apps/` finds it only in test + moduledoc). Generator (`spawn_from_template/2`) explicitly trusts the caller — moduledoc: "Generator trusts the caller... the LV `template:instantiate` cap check lands when the LV button lands". It never landed. |
| 5 | **`Agent.spawn/4` + AgentLineage** | **IMPLEMENTED** | `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex:132` — real `spawn/4` composing `SpawnRegistry.spawn` + `WorkspaceRegistry.bind` + `AgentLineage.record`. `apps/ezagent_core/lib/ezagent/agent_lineage.ex` — full registry with `record/lookup/spawned_in_lineage?/forget/list_all` and a bounded lineage walk. **Caveat:** Agent.spawn/4 explicitly does NOT add `spawned_by` as an Agent *slice* field — lineage lives only in the ETS registry (a deliberate, documented deviation from SPEC §7-3(b) "add `spawned_by` to Agent slice"). Functionally equivalent for the `{:spawned_by,_}` cap shape; the SPEC's migration-test row for the slice field is moot. |
| 6 | **Generator — `Session.spawn_from_template/2`** | **PARTIAL (the "minimal PR-41" version — never extended)** | `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:146` — real function: ensures template alive, spawns fresh session, binds workspace, spawns the embedded orchestrator agent, grants the two scope-bounded caps. **What it does NOT do (SPEC §Generator steps 3/5/6/7):** does NOT resolve `agent_slots` worker templates, does NOT spawn worker agents, does NOT install routing rules, does NOT initialize a working-copy slice. Its own moduledoc admits this: "PR 41 minimal scope... Spawns ONLY the orchestrator... Routing rule installation + working-copy slice + full agent_slots iteration are deferred to PR 46." PR 46 never delivered those. |
| 7 | **The Orchestrator + its 7 MCP tools** | **STUB / SURFACE-ONLY — does not run** | See "Orchestrator deep-dive" below. The 7 tool *functions* have real bodies (not `:not_implemented_yet`), but two of them are incomplete (return a URI without persisting a row), and — critically — **the tool surface is wired to nothing.** No MCP bridge, no agent flavor, no chat-behavior path exposes `Ezagent.Orchestrator.Tools` to a running LLM. The cc-orchestrator "agent" is an empty AgentTemplate Kind. |
| 8 | **Scope-bounded delegation caps** | **IMPLEMENTED** | `apps/ezagent_core/lib/ezagent/capability.ex:108-130` — `instance_match?/2` has real clauses for both `{:within_session, _}` (string-prefix with `/` boundary guard) and `{:spawned_by, _}` (real `AgentLineage.spawned_in_lineage?` walk — NOT a deny placeholder). `capability_test.exs` lines 309-483 cover within-scope grant, cross-scope deny, prefix-boundary, spawned_by-absent-deny, spawned_by-recorded-match, cross-lineage-deny. This is the most complete Phase-7 element. |
| 9 | **Session persistence flip** | **IMPLEMENTED — but the working-copy slice was NOT added** | `session.ex:80` — `def persistence, do: {:snapshot, :on_change}`. The flip IS done (commit `2743635` "fix(session): persistence :ephemeral → {:snapshot, :on_change}", PR #199 — note: a Phase-8/9-era PR, not a Phase-7 PR). The resume-state "PR 44 partial — flip deferred" is now stale. **However** the `template_working_copy` slice field that the flip was meant to make durable was **never added** — it exists only as a moduledoc comment in `chat.ex:78-86` ("will be ADDED... when the orchestrator tools first mutate it"). Orchestrator tools derive working-copy state from live runtime instead (see deep-dive). |
| 10 | **`mix ezagent.bootstrap` + `mix ezagent.plugin.install`** | **IMPLEMENTED** | `apps/ezagent_core/lib/mix/tasks/ezagent.bootstrap.ex` (home.init + deps.get + adopt_db + ecto.create/migrate + `SELECT 1` health check) and `ezagent.plugin.install.ex` (250 lines, real `:application.load` + start). Both functional per resume-state smoke tests. |
| 11 | **The 3 session-creation entry points** | **ABSENT (2 of 3)** | SPEC §"Session-creation entry points": (a) instantiate-from-template = `spawn_from_template/2` — exists but partial (see #6); (b) fork+instantiate = `SessionTemplate.fork/2` — **does not exist**; (c) create-blank+instantiate = `SessionTemplate.create/2` — **does not exist**. Only 1 of 3 entry points is even present, and that one is partial. |
| 12 | **VERIFICATION V1-V5** | See V1-V5 table below | 4 of the ≥10 gating tests are missing entirely; the killer-feature criteria (V2) are unmet. |

### Orchestrator deep-dive (element 7) — the critical finding

`apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex` (444 lines)
declares exactly 7 tool functions. Reading the bodies:

- `add_agent_slot` — **real.** Delegates to `Agent.spawn/4`.
- `remove_agent_slot` — **real.** Looks up + terminates the child.
- `update_agent_template` — **real.** remove + add.
- `write_matcher` — **real.** Delegates to `RuleStore.add`.
- `list_templates` — **real.** Reads `KindRegistry.list_all`, filters by `template://` host.
- `update_template` — **INCOMPLETE.** Builds the working-copy slice,
  computes the version hash, and `build_uri`s a new SessionTemplate URI —
  then **returns that URI without ever inserting a SessionTemplate row.**
  No registry write. "Older sessions unaffected / new hash row exists"
  (SPEC §"update_template mechanics") is therefore not satisfied. The
  PR-48 `:parent_template_deleted` check IS wired.
- `save_template_as` — **INCOMPLETE.** Same shape — computes a hash,
  returns a URI, **persists nothing.** No new template family is created.

So even the two persistence-writing tools do not persist.

**The decisive gap:** `Ezagent.Orchestrator.Tools` is **imported by
nothing.** Grep of `apps/` for `Orchestrator.Tools` / `Orchestrator` (in
`.ex` files) finds only the module itself and its test. There is:

- **no MCP server / bridge** that exposes these 7 tools to an LLM;
- **no agent flavor / Kind** that *is* the Orchestrator;
- **no chat-Behavior path** that routes a `@cc-orchestrator` mention into
  tool invocation.

The "cc-orchestrator AgentTemplate seed" (`application.ex:298
seed_cc_orchestrator_template`) just calls `SpawnRegistry.spawn` on
`template://agent/default/cc-orchestrator` — spawning an **empty
AgentTemplate Kind** with no `claude_config_dir`, no prompt, no
`settings_path`, no MCP tool wiring (AgentTemplate has no slice-population
code at all — see element 2).

**Conclusion: the Orchestrator does not run.** It is a tool-surface
module + a CI lock test ("exactly 7 tools, no fork, no grant_cap") and an
empty seed Kind. SPEC D7-1's "LLM-driven agent that lives in the session"
is not realised in code. The VERIFICATION V2 e2e demo (PR 49) was never
recorded because there is nothing to demo.

---

## V1-V5 verification table

| Criterion | Met? | Evidence |
|-----------|------|----------|
| **V1.1** 5-min `mix ezagent.bootstrap` onboarding | **Likely met** | bootstrap task is real + smoke-tested; but `bootstrap_to_serving_test.exs` (the CI gate) is **missing**. |
| **V1.2** esr-developer skill activates + guides | **Met (skill exists)** | `.claude/skills/ezagent-developer/SKILL.md` exists. (Note: SPEC says `esr-developer`; shipped as `ezagent-developer`.) |
| **V1.3** Self-service error resolution / runbook | **Met** | `docs/runbook/common-failures.md` exists. |
| **V1.4** Hot plugin install | **Partial** | task works; `plugin_hot_install_test.exs` gate **missing**. |
| **V2.1** Orchestrator stands up a team from NL prompt | **NOT MET** | Orchestrator does not run (deep-dive). |
| **V2.2** Mention routing isolates workers | **Separately shipped** | mention-gated routing landed Phase 9 (#226) — but not via the orchestrator. |
| **V2.3** `save_template_as` creates a reusable template | **NOT MET** | `save_template_as` persists no row. |
| **V2.4** Re-instantiation produces identical team | **NOT MET** | Generator spawns no workers; no template rows persisted. |
| **V2.5** Refinement + version-bump (`update_template`) | **NOT MET** | `update_template` persists no row. |
| **V2.6** Persistence survives restart | **Partial** | Session persistence flip done; but no `template_working_copy` slice to survive. |
| **V2.7** Error feedback for orchestrator failures | **Partial** | `:parent_template_deleted` path coded; never reached by a live orchestrator. |
| **V3.1-V3.3** Scope-bounded / lineage-bounded cap denial | **MET** | `capability.ex` + `capability_test.exs` cover all three (within_session, workspace, spawned_by). |
| **V3.4** CLI ↔ LV cap parity | **Met** | `apps/ezagent_cli/test/integration/cli_lv_cap_parity_test.exs` exists. |
| **V3.5** Feishu inbound preserves error feedback | **Met (pre-existing)** | PR 27 fix; `feishu_inbound_cap_denial_feedback_test.exs`. |
| **V3.6** Decision Log retires v0-no-delegation | **Met** | ARCHITECTURE.md Decision #137. |
| **V4.1** Repo tree has no DB | **Met** | `repo_root_clean_test.exs`. (Repo currently has `ezagent_core_test.db` files — those are *test* DBs in the tree root; worth a follow-up check.) |
| **V4.2** No v1 prototype refs | **Met** | `no_v1_bridge_after_cutover_test.exs` exists. |
| **V4.3** Zero orphan sidecars | **Met** | `sidecar_orphan_reap_test.exs` exists. |
| **V4.4** Workspace isolation in routing | **Met** | `workspace_isolation_test.exs` exists. |
| **V4.5** bootstrap one-command | **Met (task)** | gate test missing (see V1.1). |
| **V4.6** CC v2 only path | **Met** | v1 prototype deleted. |
| **V4.7** CLI per-user token auth | **Met** | `ezagent.user.token` task + parity test. |
| **V4.8** Session persistence flip == `{:snapshot,:on_change}` | **MET** | `session.ex:80`. |
| **V5.1** ≥8 invariant tests gate Phase-7 principles | **Partial** | Present: workspace_isolation, no_v1_bridge, sidecar_orphan_reap, repo_root_clean, cli_lv_cap_parity, capability scope tests, orchestrator/tools (7-tool lock). **Missing:** `orchestrator_cap_scope_test`, `template_immutable_hash_test`, `template_fork_lineage_test`, `template_tag_resolution_test`, `plugin_hot_install_test`, `bootstrap_to_serving_test`, `orchestrator_e2e_demo_test`. |
| **V5.2** Skill catches anti-patterns | **Likely met** | skill exists; `esr_developer_skill_anti_pattern_table_test.exs` not verified present. |
| **V5.3** D7-* Decision Log rows #135-#144 | **MET** | ARCHITECTURE.md rows #135-#144 (and #146) present. |
| **V5.4** GLOSSARY 16 Phase-7 terms | **Met** | GLOSSARY §624+ has AgentTemplate / SessionTemplate / Generator / Orchestrator / Scoped Delegation / version hash / template caps etc. (One stale point: GLOSSARY Orchestrator entry says "6 MCP tools" then lists 7 — minor.) |
| **V5.5** ROADMAP §9b delivery accounting | Not verified | — |
| **V5.6** `phase-7-handoff.md` declares v1 | **Met (but premature)** | exists, declares "v1 release (code-complete)" — contradicted by this audit. |
| **V5.7** 4 onboarding docs | **Partial** | `docs/onboarding/` has 3 (first-30-days, adding-a-plugin, adding-kind-behavior-template) + `docs/runbook/common-failures.md` = 4 files total, matches. |
| **V5.8** SPEC_REVIEW checklist in CONTRIBUTING | Not verified | — |

---

## Bottom line — what Phase 7 genuinely remains

Phase 7 is **roughly 55-60% real.** The *infrastructure* sub-step (7-1)
and the *delegation* primitives (7-3 caps) are genuinely done and
well-tested. The *handoff* sub-step (7-4) is mostly done. **The
killer feature it was named for — the session-template generator with a
live in-session orchestrator — is not built.** It is module skeletons,
moduledoc prose, and CI lock-tests with no working pipeline behind them.

The resume-state doc's "code-complete v1 release" is **false.** The
handoff note `phase-7-handoff.md` should be downgraded.

### Concrete unfinished items (highest-impact first)

1. **The Orchestrator does not run.** No MCP bridge / agent flavor /
   chat-behavior wiring connects `Ezagent.Orchestrator.Tools` to a live
   LLM. The cc-orchestrator seed is an empty Kind. This is the central
   gap — V2 (the killer feature) is entirely unmet.
2. **`update_template` and `save_template_as` persist nothing.** Both
   compute a hash + URI and return it; neither inserts a SessionTemplate
   registry row. Template refinement / save-as is non-functional.
3. **The Generator is the "minimal PR-41" stub.** `spawn_from_template/2`
   spawns only the orchestrator — no worker `agent_slots`, no routing
   rules, no working-copy slice. The deferred-to-PR-46 work never landed.
4. **2 of 3 session-creation entry points are absent.**
   `SessionTemplate.fork/2` and `SessionTemplate.create/2` do not exist.
   No `template_tags` registry exists.
5. **AgentTemplate / SessionTemplate are bare Kinds, not Template
   Classes.** Neither implements `Ezagent.Kind.Template`
   (`validate/1` + `instantiate/3`); neither has slice-population code.
   The slice schemas live only in moduledoc.
6. **No `template:` cap is ever enforced.** `template:instantiate` /
   `template:read` / `template:write` have zero runtime call sites — the
   Generator explicitly trusts the caller.
7. **~7 V1-V5 gating tests missing:** orchestrator_cap_scope,
   template_immutable_hash, template_fork_lineage, template_tag_resolution,
   plugin_hot_install, bootstrap_to_serving, orchestrator_e2e_demo.

### Things that ARE solid (don't re-do)

- WorkspaceRegistry, AgentLineage, `Agent.spawn/4` — complete + tested.
- Scope-bounded delegation caps (`{:within_session,_}` /
  `{:spawned_by,_}`) — complete + thoroughly tested. This was the
  SPEC's "trickiest part" and it landed properly.
- Session persistence flip — done (in a later phase's PR #199).
- `mix ezagent.bootstrap` / `mix ezagent.plugin.install` — done.
- Decision Log #135-144, GLOSSARY terms, esr/ezagent-developer skill,
  onboarding docs — done.

---

## Overlap / conflict with the cc-agent-config SPEC

`docs/superpowers/specs/2026-05-22-cc-agent-config.md` lives on branch
`origin/docs/cc-agent-config-spec` (not yet on `main`). It designs
two-layer cc-agent configuration: Layer 1 = per-agent `cwd` +
`settings_path`; Layer 2 = a cc-plugin-wide `sandbox_mode` boolean that,
when true, launches every cc agent **completely isolated from the host
`~/.claude/`** via an isolated `CLAUDE_CONFIG_DIR`.

**Direct overlap with AgentTemplate (Phase 7):**

- The Phase-7 AgentTemplate **slice schema already designed exactly this
  pattern** — its documented fields are `claude_config_dir` (→ becomes
  the `CLAUDE_CONFIG_DIR` env var), `settings_path`, `mcp_config_path`,
  `api_key_helper` (the macOS-Keychain workaround). The
  resume-state brainstorm round 3 explicitly says "AgentTemplate adds
  `CLAUDE_CONFIG_DIR` env var pattern + macOS Keychain caveat."
- **But that pattern is NOT in the AgentTemplate code today.**
  `claude_config_dir` / `CLAUDE_CONFIG_DIR` appear **only in moduledoc
  comments** in `agent_template.ex`, `agent.ex`, `tools.ex`,
  `application.ex` — there is no slice field, no env-var construction, no
  PTY-launch code that consumes it. AgentTemplate is a documented intent,
  not a working sandbox pointer.

**Therefore the two efforts collide on an empty lot, not a built one:**

- cc-agent-config's `sandbox_mode` and Phase-7's `claude_config_dir`
  are the **same mechanism** (isolated `CLAUDE_CONFIG_DIR`) described in
  two different SPECs at two different layers (cc-plugin-wide vs
  per-AgentTemplate). Whoever implements either one should reconcile:
  is the sandbox toggle plugin-wide (cc-agent-config Layer 2) or
  per-template (AgentTemplate slice)? The SPECs currently answer
  differently and neither is built.
- cc-agent-config Layer 1's per-agent `settings_path` overlaps
  AgentTemplate's `settings_path` field — same name, same purpose.
- cc-agent-config introduces a **non-bypassable PTY safety `--settings`
  override** (forces `remoteControlAtStartup: false`). If AgentTemplate's
  `settings_path` / `claude_config_dir` are later implemented naively,
  they could undo that safety override. The cc-agent-config SPEC's
  HIGH-severity finding must be honoured by any future AgentTemplate
  PTY-launch code.

**Recommendation:** before building either, decide the layering once.
The cleanest reconciliation: AgentTemplate owns the per-agent sandbox
pointer (`claude_config_dir`); the cc-plugin `sandbox_mode` toggle simply
*defaults* whether new cc AgentTemplates get an isolated dir. They are
not in conflict if sequenced — but today both are unbuilt and both SPECs
claim the `CLAUDE_CONFIG_DIR` mechanism independently.

---

## docs/notes bilingual convention

`docs/notes/` follows the `<name>.md` + `<name>.zh_cn.md` parallel-file
convention (e.g. `phase-8-deploy-notes.zh_cn.md`, `uri-design.zh_cn.md`,
`v1-stress-test-results-2026-05-22.zh_cn.md`). A Chinese parallel of this
audit — `phase-7-implementation-audit-2026-05-22.zh_cn.md` — should be
written alongside it for Allen.
