# T7 — Socialware Data Split & Deployment Shape (proposal + first slice)

> **Owner:** gaga · **Reviewer (blocking):** jjkysy · **Date:** 2026-07-01
> **Branch:** `feat/socialware-data-deployment-shape-0701` · **Base:** `origin/main`
> **Authoritative boundary:** `docs/together/contributing/socialware-data-deployment-boundary.md` (P6)
> **Companion assessment:** `docs/together/2026-07-01/notes/pr1110-1116-1117-t7-assessment.md` (#1110 → #1116/#1117 decomposition)

## TL;DR

A socialware app must split into **three separable carriers** — *definition
data*, *runtime substrate*, *installer/deployment flow*. Today AutoService
(#1106) and kanban (#1110) each collapse all three into one artifact (an 816-line
seed script; a salvage integration branch).

This PR does two things:

1. **Proposal:** applies the boundary concretely to **both** AutoService and
   kanban, defines the target socialware *package* shape + installer contract,
   and names the supported-path gaps that belong to jjkysy's T6 substrate split.
2. **First slice (landed):** moves the AutoService **KB corpus** and **support
   persona** out of seed *code* into **package data** under
   `apps/ezagent_domain_session/priv/socialware/autoservice/`; the seed now reads
   them. The Tier-1 regression stays green.

This is deliberately one small proof, not the whole packaging system.

## 1. The boundary (recap of P6, authoritative doc for detail)

| Carrier | What it is | Rule |
|---|---|---|
| **Definition data** | product-specific content/config; swap the app → swap this | persona/soul, KB/resource fixture, SessionTemplate, routing, role recipes, cap requests, surface declaration |
| **Runtime substrate** | generic mechanisms that run **any** socialware app | no product business logic; lives in domain/plugin substrate, not in the app's data or its installer |
| **Installer / deploy flow** | repeatable install of definitions into a workspace + verify | a seed is *allowed* as installer/harness; it is **not** the product definition |

## 2. AutoService decomposition

`scripts/autoservice_tier1_seed.exs` (816 lines) currently carries all three. Map:

| In the seed | Carrier | Target home |
|---|---|---|
| `@kb_corpus` (ZEPHYR-7731 soul anchor) | **definition data** | ✅ `priv/socialware/autoservice/kb/tier1-corpus.md` *(this PR)* |
| `support_persona/1` (agent `CLAUDE.md`) | **definition data** | ✅ `priv/socialware/autoservice/persona/support-agent.md` *(this PR)* |
| `ensure_public_view_session/2` (public_view + `web_anon_access` + installs) | **definition data** | `session/tier1.yaml` *(declared in `package.yaml`; wiring is a follow-up slice)* |
| `ensure_always_to_agent_rule/2` (`always(in_session)→agent`) | **definition data** | `routing/always-to-agent.yaml` *(follow-up)* |
| `register_recipes/3` minimal role + `kb.query` request | **definition data** | `roles/autoservice.yaml` *(follow-up)* |
| `ensure_workspace`, `ingest_corpus`, `join_member`, dispatch ordering | **installer flow** | a generic `Socialware.Installer` *(follow-up)* |
| `maybe_bind_session_orchestrator` (hand-written working-copy), `maybe_register_orchestrator` (`McpRegistry.register`), `maybe_ensure_session_manager` (`SessionManager.ensure_started`) | **runtime substrate** | ⚠️ **supported-path gaps → jjkysy T6** (see §5) |

### Target package layout

```
priv/socialware/autoservice/          # definition data (0 lines of Elixir)
├── package.yaml                       # manifest: what is data / what is declared
├── persona/support-agent.md           # ✅ this PR
├── kb/tier1-corpus.md                 # ✅ this PR (fact_token ZEPHYR-7731)
├── session/tier1.yaml                 # follow-up
├── routing/always-to-agent.yaml       # follow-up
└── roles/autoservice.yaml             # follow-up
```

The seed shrinks from "everything" toward a thin **installer/verifier** that reads
this package and drives supported paths.

## 3. Installer / deployment contract

A generic installer (target: `Ezagent.Socialware.Installer`, built on the
existing `Ezagent.Socialware.{Installation, DefinitionRegistry}` in
`ezagent_domain_session`) should expose one repeatable flow for **any** package:

| Step | Supported path today | Status |
|---|---|---|
| ensure workspace | `Workspace.create/2` | ✅ |
| ingest resources | `kb.ingest` dispatch | ✅ |
| persist session shape | `SessionTemplate.persist_version_as_system/2` | ✅ |
| install routing | `RuleStore.add/…` | ✅ |
| materialize agent(s) | cc-orchestrator via template-content spawn | ⚠️ gap → **#1116** (`SessionAgentMaterialize` + `GrantRecipeCaps`) |
| grant caps | `Identity.grant_cap/3` (CapBAC chokepoint) | ✅ |
| verify | smoke / E2E (retrieval proven; answer-loop is the live-cc GAP) | ✅ / GAP |

## 4. Kanban decomposition (same boundary, aligned to jjkysy T6 / #1110 split)

| #1110 fragment | Carrier | T6 slice |
|---|---|---|
| board workflow stages, PM/dev role recipes, PM persona | **definition data** | package/recipe data + PM persona slice |
| generic role-agent materialization (`SessionAgentMaterialize`), World UI surface provider (`nav_surfaces/0`, `session_tabs/0`) | **runtime substrate** | ✅ already split: **#1117** UI surface (`feat/kanban-split-a`) + **#1116** role-agent materialization (`feat/kanban-split-b`) |
| `Behavior.Kanban`, kanban manager, GitHub gateway, PR sync, World Kanban UI | **plugin runtime** | kanban+GitHub business plugin slice |
| create session/team/board from package data + E2E | **installer flow** | install/deploy step |
| demo / evidence docs | **fixture/demo-only** | not a merge unit |

→ AutoService and kanban land on the **same** three carriers and the **same**
installer contract. The generic role-agent materialization both need is exactly
jjkysy's T6 "generic role-agent materialization substrate" — T7 does not
re-implement it.

## 5. Substrate dependencies — #1116 / #1117 (supported-path gaps)

The generic substrate T7's installer needs is **already split from #1110** as two
open PRs; T7 cites them as the expected direction and does **not** re-implement
them:

- **#1117** (`feat/kanban-split-a`) — World-side plugin **UI-surface substrate**
  (`Ezagent.World.UiSurfaceProvider`, `nav_surfaces/0`, `session_tabs/0`): the
  canonical home for the **surface-declaration** carrier. A package declares a
  surface exists; World owns the shell convention + rendering. Distinguish
  *surface declaration* (package data) from *surface runtime/rendering* (World).
- **#1116** (`feat/kanban-split-b`) — generic per-session **role-agent
  materialization** (`SessionAgentMaterialize`, `DefaultAgentSeed`,
  `GrantRecipeCaps` chokepoint, cc role support): the supported path for the
  AutoService seed's hand-stitched calls. `maybe_register_orchestrator`
  (`McpRegistry.register`), `maybe_ensure_session_manager`
  (`SessionManager.ensure_started`), `maybe_bind_session_orchestrator`
  (hand-written working-copy) are **supported-path gaps**, not product data — they
  should route through #1116 once it lands.

T7's first AutoService slice does **not** block on #1116/#1117; it cites them as
the substrate direction.

**Boundary risk to preserve (from #1116):** #1116 intentionally drops
`DefaultRecipes`/`DefaultRecipeSeed`. Keep the split:

- **Substrate** = "materialize role X for session Y and grant declared caps".
- **Definition data** = "role X *is* `pm-coordinator` with these skills / prompts /
  caps / board assumptions".

Do **not** promote product recipes (`pm-coordinator`, `dev-together`) into
`ezagent_domain_agent` defaults unless the lead explicitly makes them platform
defaults.

## 6. First slice — evidence

- **Changed:** `@kb_corpus` heredoc + `support_persona/1` heredoc removed from the
  seed; seed reads `priv/socialware/autoservice/{kb,persona}/…` via
  `Application.app_dir(:ezagent_domain_session, …)` (resolves in both the live
  serve-seed and the `Code.require_file` test).
- **Kept:** `@kb_fact_token "ZEPHYR-7731"` as the test's soul anchor; the corpus
  file carries the literal token (mutual drift guard — the retrieval assert fails
  if either drifts).
- **Test:** `mix test apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs --include integration` → **2 tests, 0 failures**; not skipped (no `SKIP` on stderr); the retrieval assertion (hit contains ZEPHYR-7731) exercises `ingest_corpus → kb_corpus() → package file`.
- **Persona** is only exercised on the live cc path (test uses a generic flavor);
  it shares `package_dir()` with the corpus, so the green corpus path confirms the
  persona file resolves. Its live end-to-end proof is delegated to **T5's
  re-verification (二测) on the T7-merged base** — T5 runs the live cc customer flow.

## 7. Follow-up slices (not this PR)

1. session/routing/roles → `package.yaml`-referenced data + a `Socialware.Installer` that consumes them.
2. Route the seed's hand-stitched `McpRegistry.register` / `SessionManager.ensure_started` / working-copy binding through **#1116** once it lands; delete the gaps.
3. Apply the same package shape to kanban once **#1116/#1117** land.

## 8. Coordination — T7 → T5

T7 and T5 share `scripts/autoservice_tier1_seed.exs`. T7 restructures how the seed
sources its definition data (corpus + persona → package files), so **land T7
first, then T5 re-verifies (二测) the customer flow on the T7-merged base.** This
is also the live end-to-end proof of the persona slice, which T7's own unit test
cannot reach (see §6).

## Boundary checklist (PR-rule — same 5 questions for AutoService & kanban)

- **What is definition data?** KB corpus + support persona (moved to package this PR); session/routing/roles (declared in `package.yaml`).
- **What is runtime substrate?** `Socialware.{Installation, DefinitionRegistry}` (exists); role-agent materialization → **#1116**; UI-surface declaration → **#1117**.
- **What is install/deploy flow?** the seed as transitional installer; generic `Socialware.Installer` (follow-up).
- **What is fixture/demo-only?** none in this PR.
- **Which supported-path gaps remain?** `McpRegistry.register` / `SessionManager.ensure_started` / hand-written working-copy binding in the seed → route through **#1116** when it lands.
- **Both apps:** AutoService (this PR) and kanban (§4) map to the same carriers + installer contract; #1116/#1117 are the clean substrate splits from #1110.
