# dev-together plan — 2026-06-24 (team dev plan)

```yaml
planned_at: 2026-06-24
lead: Allen (林懿伦)
timezone: GMT+9
scope: HUMAN developers only (codex + Claude excluded — they run as support/orchestration off-plan)
basis: continuity from the 2026-06-23 returns (docs/together/2026-06-23/returns/)
base_main: c2365462
```

## Weekly goals (本周) — what the daily tracks ladder up to

1. **Get ezagent running inside the team** — the product works end-to-end well
   enough that the team uses it daily. zyli's 人肉 run is the *measurement* of
   this; gaga (cc-headless), fatnine (agent-console), zhaomato (hello), and the
   session-create crux fix are the *gaps* that block it.
2. **Build the official website (官网)** — a public marketing/landing site for
   ezagent. **Owner: zhaomato** (lead-assigned 2026-06-24) — built on the proven
   `@json-render` render substrate hello already uses (vercel-labs `@json-render`
   core+react 0.19.0 + `catalog.ts`/`registry.tsx`), reusing zhaomato's hello
   expertise.

| Track | Serves goal |
|---|---|
| zyli 人肉 full-flow | ① (the measurement) |
| gaga cc-headless real → then agent-console QA | ① (agent coverage + launch-readiness of operator config) |
| fatnine #84 agent-console | ① (operator can manage agents) |
| zhaomato 官网 | ② (built on the json-render substrate) |

> Each track below CONTINUES yesterday's work; the concrete next increment is
> derived from that dev's 2026-06-23 return. Conflict map at the bottom — the four
> tracks are largely disjoint plugins, so they parallelize cleanly.

## Tracks

| Dev | Track (continuity) | Today's increment (from yesterday's return) | Branch | Owned surfaces | Required reading |
|---|---|---|---|---|---|
| **zyli** (zylideveloper) | 人肉 full-flow validation (was `world-deploy-e2e-pg`) | Re-run the end-to-end operator flow on a fresh disposable **PG** stack now that session-create↔orchestrator decouple (#912) landed. **Verify the root-caused crux is cleared** — `create_session` 5s-dispatch timeout + snapshot-on-create race → session w/o respawnable snapshot → `:no_such_actor` (return §7). Walk steps 1→8; capture evidence per step; file/route each remaining blocker (a found bug spawns a `fix/<symptom>` branch). | n/a (validation) + `fix/*` as found | disposable stack, `docs/together/2026-06-24/evidence/`, the world-e2e runbook | own 2026-06-23 return §7 + `docs/guide/world-e2e-seed.md` |
| **gaga** (gagameow) | protocol-api / agent-flavor → agent-console QA | **AM: implement the REAL `cc-headless` backend** — replace the spawn-STUB (`CcHeadlessAgent` returns success without starting Claude). 3B (`server:esr-bridge` no-PTY) verified **NOT viable** vs Claude 2.1.186 → implement **3A** per the handoff. **Then: guide + test fatnine's #84 agent console** — ensure ALL autoservice backend config functions are present + working **before launch** (the operator can configure every agent-config field via the console; gaga is the backend/agent-flavor expert pairing with fatnine's UI). | `feat/cc-headless-real` (+ review/pairing on `feat/agent-console-crud`) | `apps/ezagent_plugin_cc`; then QA across `plugin_world` agent-console + `ConfigEvolve`/agent-config backend | `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md` (§3A) + the #84 handoff |
| **zhaomato** | 官网 (official website) — goal ② | **Build the ezagent official website** on the proven `@json-render` render substrate hello already uses (vercel-labs `@json-render` core+react 0.19.0 + `catalog.ts`/`registry.tsx`). Reuse the hello render expertise. **[scope to confirm with Allen: content/sections, hosting (CF Workers per #65?), public route].** | `feat/official-site` | new site assets (likely a world/hello-render-based public surface) | hello `@json-render` setup (`apps/ezagent_plugin_hello/assets`) + #65 CF Workers deploy |
| **fatnine** | agent console | **#84 Agent Console CRUD** — the re-scoped, lead-decided handoff is READY (Modify = full config cascade via `apply_config_delta`; delete-gate = manage-cap+confirm+block-while-bound; create-fields read-only; live-status fix in-scope). Builds on #905. Demonstrable-DoD (post-mutation backend state, the anti-demo bar #904 lacked). | `feat/agent-console-crud` | `apps/ezagent_plugin_world` (agent detail/list/edit/delete) | `docs/together/2026-06-24/handoffs/agent-console-crud-handoff.draft.md` (READY) + #905 |

## Conflict map

- **Largely disjoint surfaces** → clean parallelism: gaga AM=`plugin_cc`, zhaomato=新官网 assets (reads hello's `@json-render` setup, doesn't mutate `plugin_hello` runtime), fatnine=`plugin_world` agent pages.
- **gaga ↔ fatnine pairing (PM)**: after cc-headless, gaga QAs/guides fatnine's #84 on `feat/agent-console-crud` — same branch, so gaga reviews/tests rather than edits in parallel (no concurrent writes; fatnine owns the branch, gaga drives the autoservice-backend-config completeness checklist).
- **World UI**: fatnine owns the world **agent pages**; no other dev mutates world infra (zyli→人肉). Respect `docs/guide/world-coordination.md` (declare surfaces; serialize `styles.css`; layout gate) if a 人肉-found fix touches world.
- **zyli's 人肉 run** surfaces bugs that may spawn `fix/*` branches in shared areas (core/session). Route each per-bug at discovery; the create_session crux fix in particular touches `ezagent_domain_session` — coordinate if it lands same-day.
- **Shared resource**: one disposable stack for zyli's run (serial, single runner).

## Handoff order

All four tracks are independently startable now (fatnine's handoff is READY; gaga's cc-headless handoff exists; zhaomato's needs a 5-min scope-confirm with Allen; zyli's is a re-run of an existing flow). No inter-track dependency for start.

## Off-plan (support, not human-dev tracks)

- **Claude (me)**: finish resource-type PR-2 (world layout → resource://) + verify/merge; then available for the session-create crux fix if zyli's run needs it.
- **codex**: bounded verifiable sub-tasks on request (e.g. #55 doc-coverage burn-down batch).
