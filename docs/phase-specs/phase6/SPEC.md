# Phase 6 — Production Hardening + Three-Layer Architecture

**Status:** **LOCKED v2** 2026-05-17 (Allen brainstorm 7+ rounds, autonomous implementation underway).
**Theme:** Articulate core/domain/plugin three-layer model in code; close Phase 5 known gaps (CC channel v2, EZAGENT_HOME DB migration); ship multi-user end-to-end (routing + UI + CLI auth); validate "UI as plugin" by extracting current admin LV into `esr_plugin_ezagent`; introduce shadcn-like component library; lay groundwork for Python plugin ecosystem.

## North star

After Phase 6, a small team can:
- Each log in as their own user with cap-scoped permissions (LV + CLI + Feishu all enforced uniformly via the same dispatch path + cap check)
- Run their own deployment from `~/.ezagent/<profile>/` with SQLite + creds living there (no repo pollution)
- See a polished shadcn-style admin UI (the ezagent plugin) that's distinguishable from Phase 5's bare LV
- Have CC instances connect via production WS (Phase 1 prototype HTTP/SSE gone)
- Bind multiple Feishu apps to different workspaces (multi-tenant ready)
- Plugin authors can ship plugins in pure Elixir today; Python plugin authors get a documented `Ezagent.Python` contract (impl Phase 7)

## Three-layer model (LOCKED)

| Layer | Content | Who owns |
|---|---|---|
| **core** | Protocols + mechanisms only. URI / Invocation / Behavior contract / Kind contract / 4 Registry / Snapshot.Writer / Audit / ReadyGate / Idempotency / Capability struct / **UI.Form behaviour** / Ezagent.Runtime / Ezagent.Home / CCEvents / Routing.Matcher AST / Resolver / RuleStore | Ezagent team — plugin authors don't read it |
| **domain** | Canonical biz primitives + canonical operator surfaces. Chat / Identity / Workspace / RoutingAdmin / concrete matchers / DefaultRules / MentionRouting+SessionRouting tables / **CLI engine + Mix.Tasks.Esr shell** / **LV base components + auto-derive engine** / **JSON API auto-derive** / **Python execution contract** | Ezagent team — plugin authors import but cannot change |
| **plugin** | Adapters + instances + UI implementations. ezagent_plugin_feishu / ezagent_plugin_cc / ezagent_plugin_cc / ezagent_plugin_echo / **esr_plugin_ezagent** (default admin UI, distinct from base LV components) / future esr_plugin_python_sdk / future custom UI plugins | Anyone — adding/removing one doesn't affect others |

## App layout after Phase 6

```
apps/
├── ezagent_core/                       — protocols + mechanisms only
├── ezagent_domain_chat/                — Chat Behavior + Session/Agent Kind + routing tables + DefaultRules
├── ezagent_domain_identity/            — User Kind + Users table + Identity Behavior + Capability.Parser
├── ezagent_domain_workspace/           — Workspace Kind + Loader + Store + RoutingAdmin synthetic Kind
├── esr_domain_cli/                 — TreeBuilder + Dispatch + Coercion + Formatter + Mix.Tasks.Esr
├── esr_domain_web/                 — Phoenix Endpoint + controllers + router + JSON API (6e)
├── ezagent_domain_ui/                  — Base LV components (Card/Button/Table/Modal/etc) + AutoForm + AutoList/Detail/Edit
├── ezagent_domain_python/              — Ezagent.Python skeleton + README contract (impl Phase 7)
├── esr_plugin_ezagent/             — Current admin LV pages, rewritten with ezagent_domain_ui shadcn-style components
├── ezagent_plugin_cc/              — PtyServer for local claude (unchanged)
├── ezagent_plugin_cc/          — CC v2 Phoenix.Channel WS endpoint (v1_prototype DELETED in 6a)
├── ezagent_plugin_feishu/              — Feishu Receiver Kind + WebhookPlug + multi-app support (6d)
└── ezagent_plugin_echo/                — Test agent (unchanged)
```

DELETED in Phase 6: `apps/ezagent_web_liveview/`, `apps/ezagent_plugin_cc_bridge_v1_prototype/`, `apps/esr_plugin_chat/` (renamed/extracted).

## Decisions (LOCKED — Allen confirmed in brainstorm rounds)

| # | Question | Decision |
|---|---|---|
| P6-D1 | CC v2 wire transport | Phoenix.Channel WS |
| P6-D2 | v1_prototype removal timing | Same PR as v2 — atomic swap |
| P6-D3 | EZAGENT_HOME DB migration | `mix ezagent.home.adopt_db` task: copy, switch, verify, operator deletes old manually |
| P6-D4 | DB path source | env-driven via `Ezagent.Home.path(:db)`, no hardcoded strings |
| P6-D5 | CLI auth: cookie vs per-user token | **BOTH** — admin via cookie (default), non-admin via bearer token in :rpc.call ctx (6c.3) |
| P6-D6 | Feishu user cap-grant UI | per-user form in ezagent plugin |
| P6-D7 | Workspace-scoped routing | Extend `routing_rules` with `workspace_uri TEXT NULL` column |
| P6-D8 | Multi-Feishu-app | per-app GenServer keyed by app_id; feishu.yaml accepts multiple entries |
| P6-D9 | Domain layer file layout | Split per subdomain (6 apps: chat/identity/workspace/cli/web/ui/python) |
| P6-D10 | Layer purity CI gate | `apps/ezagent_core/test/invariants/layer_purity_test.exs` grep plugin imports; exempt via `# layer-purity-exempt:` |
| P6-D11 | Routing per-user filter | per-rule `applies_to_users: [uri] \| nil` column |
| P6-D12 | Admin UI plugin name | `esr_plugin_ezagent` (Allen: "current form exceeds admin") |
| P6-D13 | shadcn-style approach | Own small HEEx component library, Tailwind-class-based, slate neutrals, replicates shadcn aesthetic without React dependency |
| P6-D14 | LV vs React final call | LV (auto-derive friendly + Python ecosystem friendly + local-first perf advantage) — React deferred to Phase 7+ if needed |
| P6-D15 | Domain.Python in Phase 6 | Placeholder skeleton + README only; JSON-RPC stdio impl deferred to Phase 7 |
| P6-D16 | JSON API auto-derive | Same TreeBuilder source as CLI; emit `/api/v1/<kind>/<action>` routes; zero hand-coded API |

## PR plan (LOCKED — 12 PRs)

| PR | Theme | Layer | LOC est |
|---|---|---|---|
| 1 | **6b** EZAGENT_HOME DB migration (`mix ezagent.home.adopt_db` + config refactor) | core+domain | ~200 |
| 2 | **6h.1** Domain extraction part 1: rename esr_plugin_chat → ezagent_domain_chat; create ezagent_domain_identity (extract User/Users/Identity/Capability.Parser from core); create ezagent_domain_workspace (extract Workspace/Loader/RoutingAdmin from core) | core→domain | ~250 |
| 3 | **6h.2** Domain extraction part 2: rename ezagent_web → esr_domain_web; rename ezagent_cli → esr_domain_cli; split ezagent_web_liveview → ezagent_domain_ui (base components incl shadcn-like primitives) + esr_plugin_ezagent (admin pages rewritten with new components). Add `layer_purity_test.exs` CI gate | rename+extract+CI | ~600 |
| 4 | **6a** CC channel v2 (Phoenix.Channel WS) + delete ezagent_plugin_cc_bridge_v1_prototype | plugin | ~500 net (~-460 from v1 delete) |
| 5 | **6c.1** Per-rule applies_to_users + Resolver filter + LV form | domain | ~250 |
| 6 | **6c.2** Feishu user cap-grant UI in ezagent | plugin | ~200 |
| 7 | **6c.3** CLI per-user token + bearer auth | domain | ~250 |
| 8 | **6d** Workspace-scoped routing + multi-Feishu-app | core+plugin | ~300 |
| 9 | **6e** Canonical auto-derived JSON API | domain | ~300 |
| 10 | **6f** Domain.UI auto-derive list/detail/edit pages | domain | ~400 |
| 11 | **6g** Domain.Python placeholder (ezagent_domain_python/ skeleton + README contract) | domain (placeholder) | ~100 |
| 12 | **6h.3 + closeout** Docs (ARCH §17 three-layer + Domain.Python contract + GLOSSARY 5 new entries + Roadmap Phase 6 done) + dead-code scan + Phase 5 regression test + demo video | docs+QA | ~150 |

**Total ~3500 LOC net** (+4000 new, -460 from v1 delete, plus ~250 from layout reorg overhead).

## Invariant tests (per `feedback_completion_requires_invariant_test`)

- **PR 1**: `mix ezagent.home.adopt_db` against sample SQLite → `Workspace.Store.list_all/0` from new path returns same rows
- **PR 2**: After domain extraction, all existing tests pass (zero behavior change — pure reorganization)
- **PR 3**: `layer_purity_test.exs` fails on `Ezagent.Routing.RuleStore` direct call from plugin code (whitelist via `# layer-purity-exempt`)
- **PR 4**: 100 messages via new WS path → 100 audit rows + 100 actual CC stdin writes (same gate as Phase 5 PR #40)
- **PR 5**: Rule `applies_to_users: [user://alice]` → alice's msg triggers, bob's msg doesn't
- **PR 6**: Non-admin user with `chat.send` cap can send via Feishu without `:unauthorized`
- **PR 7**: CLI with `--token X` runs as non-admin user, hits CapBAC
- **PR 8**: Same matcher in two workspaces → only fires for the matching workspace's session
- **PR 9**: For every Behavior X.action, `POST /api/v1/X/action` route exists; CLI subcommand exists; LV form exists — all three from same TreeBuilder
- **PR 10**: Register a fake `:test_action` Behavior → list/detail/edit pages auto-appear at `/admin/<kind>/...`
- **PR 11**: `Ezagent.Python` module exists with stub functions; README explains JSON-RPC stdio contract
- **PR 12**: Phase 5 regression — admin↔CC conversation visible in both LV and Feishu

## SPEC_REVIEW walkthrough

### A. Architecture alignment
- A1: Roadmap §9 (Phase 6 entry) updated by PR #52
- A2: ARCH §5.4 (RoutingRegistry), §5.5 (additive rules), §9 (Template), §17 (will be updated by PR 12); Decisions #21+#22 (Behavior in plugin) REVISED by domain layer
- A3: New Decision Log entries to be added in PR 12

### B. Plugin shape
- B1 Receiver Kind: CC v2 ChannelServer is a stateful Kind. Feishu/CC plugin both follow Receiver Kind contract
- B2 Boot order: cc_channel after ezagent_domain_chat (depends on Session); ezagent after all domain apps
- B3 Storage: EZAGENT_HOME credentials; SQLite for routing_rules/users; ETS for Registries; GenServer for per-instance ChannelServer state

### C. Invariant tests
- 12 per-PR gates listed above
- 3 cross-cutting CI gates total after Phase 6: `routing_consolidation_invariant_test` + `receiver_kind_pattern_test` + `layer_purity_test`

### D. User-assist steps (per `feedback_flag_user_assist_steps`)
- **PR 1**: Allen runs `mix ezagent.home.adopt_db` once, verifies, deletes old `ezagent_core_dev.db`
- **PR 4**: Allen restarts local CC bridges with new attach command (v1 disconnects on merge)
- **PR 6**: Allen grants caps for Feishu users via the new UI
- **PR 7**: Allen tests CLI token flow (token from `mix ezagent.user.token`)
- **PR 8**: Allen provisions additional Feishu apps in `feishu.yaml`

### E. Drift defenses
- PR 2/3 themselves ARE drift defenses
- `layer_purity_test.exs` becomes third Layer-2 CI gate
- Memory `feedback_phase_planning_reads_main_docs` enforces SPEC review for Phase 7+

## Non-goals (deferred to Phase 7+)

- Federation MVP (bundled with multi-tenant brainstorm)
- React SPA frontend (LV with auto-derive covers it; React only if specific use case emerges)
- Plugin scaffolder (mix ezagent.gen.plugin) — needs ≥3 third-party plugins
- Python plugin SDK + first Python plugin demo — Phase 7
- Workspace clone / template publish
- Audit log retention / GDPR

## Brainstorm provenance

This SPEC distills 7+ rounds of conversation with Allen on 2026-05-17:
- Started with 6-PR plan (Federation in scope)
- Round 2: Federation cut, multi-user added
- Round 3: shadcn-like UI question → React SPA proposed
- Round 4: Allen's Python community + local-first concerns → LV-with-auto-derive preferred
- Round 5: 3-layer model articulated (core/domain/plugin)
- Round 6: UI also-as-domain; admin pages as ezagent plugin
- Round 7: Domain.Python placeholder; JSON-RPC stdio contract
- Final: 12 PR scope, AFK autonomous execution

See companion: `docs/notes/post-phase-5-meta-report.md`, `docs/notes/plugin-receiver-kind-contract.md`, `docs/notes/spec-review-checklist.md`
