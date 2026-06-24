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
| **zyli** (zylideveloper) | 人肉 full-flow validation (was `world-deploy-e2e-pg`) | Re-run the end-to-end operator flow **on his own host** (disposable stack retired this week — see standing rules) now that session-create↔orchestrator decouple (#912) landed. **Verify the root-caused crux is cleared** — `create_session` 5s-dispatch timeout + snapshot-on-create race → session w/o respawnable snapshot → `:no_such_actor` (return §7). Walk steps 1→8; capture evidence per step; file/route each remaining blocker (a found bug spawns a `fix/<symptom>` branch). The snapshot-race fix itself is @林懿伦's (core handoff). | n/a (validation) + `fix/*` as found | own host; `docs/together/2026-06-24/evidence/`; the world-e2e runbook | own 2026-06-23 return §7 + `docs/guide/world-e2e-seed.md` |
| **gaga** (gagameow) | protocol-api / agent-flavor → agent-console QA | **AM: implement the REAL `cc-headless` backend** — replace the spawn-STUB (`CcHeadlessAgent` returns success without starting Claude). 3B (`server:esr-bridge` no-PTY) verified **NOT viable** vs Claude 2.1.186 → implement **3A** per the handoff. **Then: guide + test fatnine's #84 agent console** — ensure ALL autoservice backend config functions are present + working **before launch** (the operator can configure every agent-config field via the console; gaga is the backend/agent-flavor expert pairing with fatnine's UI). | `feat/cc-headless-real` (+ review/pairing on `feat/agent-console-crud`) | `apps/ezagent_plugin_cc`; then QA across `plugin_world` agent-console + `ConfigEvolve`/agent-config backend | `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md` (§3A) + the #84 handoff |
| **zhaomato** | 官网 (official website) — goal ② | **Build the ezagent official website** on the proven `@json-render` render substrate hello already uses (vercel-labs `@json-render` core+react 0.19.0 + `catalog.ts`/`registry.tsx`). Reuse the hello render expertise. **[scope to confirm with Allen: content/sections, hosting (CF Workers per #65?), public route].** | `feat/official-site` | new site assets (likely a world/hello-render-based public surface) | hello `@json-render` setup (`apps/ezagent_plugin_hello/assets`) + #65 CF Workers deploy |
| **fatnine** | agent console | **#84 Agent Console CRUD** — the re-scoped, lead-decided handoff is READY (Modify = full config cascade via `apply_config_delta`; delete-gate = manage-cap+confirm+block-while-bound; create-fields read-only; live-status fix in-scope). Builds on #905. Demonstrable-DoD (post-mutation backend state, the anti-demo bar #904 lacked). | `feat/agent-console-crud` | `apps/ezagent_plugin_world` (agent detail/list/edit/delete) | `docs/together/2026-06-24/handoffs/agent-console-crud-handoff.draft.md` (READY) + #905 |

## Conflict map

- **Largely disjoint surfaces** → clean parallelism: gaga AM=`plugin_cc`, zhaomato=新官网 assets (reads hello's `@json-render` setup, doesn't mutate `plugin_hello` runtime), fatnine=`plugin_world` agent pages.
- **gaga ↔ fatnine pairing (PM)**: after cc-headless, gaga QAs/guides fatnine's #84 on `feat/agent-console-crud` — same branch, so gaga reviews/tests rather than edits in parallel (no concurrent writes; fatnine owns the branch, gaga drives the autoservice-backend-config completeness checklist).
- **World UI**: fatnine owns the world **agent pages**; no other dev mutates world infra (zyli→人肉). Respect `docs/guide/world-coordination.md` (declare surfaces; serialize `styles.css`; layout gate) if a 人肉-found fix touches world.
- **zyli's 人肉 run** surfaces bugs that may spawn `fix/*` branches in shared areas (core/session). Route each per-bug at discovery; the create_session crux fix in particular touches `ezagent_domain_session` — coordinate if it lands same-day.
- **No shared stack this week** (lead 2026-06-24): every dev track runs on the dev's **own host**; the disposable stack is NOT used this week. To view another dev's running work, use the **intranet Tailscale (tailnet) address** of their host — no shared-runner contention.

## Handoff order

All four tracks are independently startable now (fatnine's handoff is READY; gaga's cc-headless handoff exists; zhaomato's needs a 5-min scope-confirm with Allen; zyli's is a re-run of an existing flow). No inter-track dependency for start.

## Off-plan (support, not human-dev tracks)

- **Claude (me)**: finish resource-type PR-2 (world layout → resource://) + verify/merge; then available for the session-create crux fix if zyli's run needs it.
- **codex**: bounded verifiable sub-tasks on request (e.g. #55 doc-coverage burn-down batch).

---

## NEXT task for 张宁 (zhaomato) — 官网/hello json-render 重做 (lead analysis 2026-06-24)

@林懿伦 2026-06-24: 官网（#956 已落地，PR #961）"看起来太丑了，json-render 没有用好"。Reference of "good" = the demo Allen built with codex: **http://100.64.0.27:5173/** (repo **github.com/ezagent42/json-render-demo**) — a polished shadcn/Tailwind landing page (bold hero, stat cards, feature blocks, pricing tiers, FAQ accordion, CTA). Plus a **design system** Allen will hand over (style separation), and the goal that **每个 session 的 hello 都能单独指定自己的样式**.

### Root cause (lead analysis — code-verified)
1. **前后端 catalog 脱节 = 直接的"坏/丑"**. #956 migrated the BACKEND catalog `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex` to **36 capitalized shadcn types** (`Stack/Grid/Card/Heading/Text/Button/Link/Image/Badge/Tabs/Accordion/Table/Input/...`) and the prompts (`prompts.ex`) inject that set — but the **FRONTEND renderer was NOT migrated**: `apps/ezagent_plugin_hello/assets/src/catalog.ts` + `registry.tsx` still only know the **old 7 lowercase** types (`page/section/card/heading/text/button/image`). So the LLM now emits `{"type":"Stack"}`, `{"type":"Heading"}`, … which the frontend @json-render catalog doesn't recognise → nodes fail validation / render nothing → the page is mostly empty/fallback. Same incomplete-shadcn-migration that left #956's tests red (lead fixed the tests to land it; the **frontend renderer desync is the remaining runtime half**).
2. **即便对齐了也丑**: `registry.tsx` renders its 7 components with **hand-rolled inline styles** (`border:1px #e5e7eb`, etc.), not real shadcn components, no theme. Meanwhile the **world operator UI already has a proper Tailwind/shadcn design-token system** (`apps/ezagent_plugin_world/assets/src/styles.css` + `components/ui/primitives.tsx`) that the hello renderer does NOT reuse. "json-render 没用好" = map the catalog to real shadcn components, not bare inline divs.
3. **无 per-session 样式**: #956 added a shell channel (`TurnDriver.set_shell` → `Surface.handle_set_shell` stores HTML + CSS) — a starting point — but the json-render body uses fixed inline styles, so a session can't theme its own page.

### Task (zhaomato, next cycle)
1. **Align the frontend catalog to the backend shadcn set**: rewrite `catalog.ts` + `registry.tsx` so the frontend @json-render catalog == `spec.ex`'s 36 capitalized components, each implemented as a **real shadcn/Tailwind component** (reuse/align with world's `primitives.tsx` + design tokens; reference the `json-render-demo` renderer). Do NOT touch `spec.ex` (backend catalog is already correct/shadcn).
2. **Design system / style separation**: per Allen's incoming design system, extract design tokens (color/radius/shadow/type/spacing) into one theme layer; json-render components reference tokens, never hardcode styles.
3. **Per-session theme override**: each session's hello can specify its own theme (a design-token / CSS-variable set). Extend the existing `set_shell` channel into a per-session theme override that the json-render body applies at render.
4. **Gate / DoD**: `mix precommit` green (CI now enforces it on PRs); plus a visual E2E — generate a page → render at `/socialware/customer` → **agent-browser screenshot** compared against the demo's quality bar.

### Key files
- Frontend renderer (rewrite): `apps/ezagent_plugin_hello/assets/src/{catalog.ts, registry.tsx, main.tsx}`
- Backend catalog (reference, do NOT change): `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex` (+ `prompts.ex`)
- Existing design tokens to reuse: `apps/ezagent_plugin_world/assets/src/{styles.css, components/ui/primitives.tsx}`
- Per-session shell/theme channel: `TurnDriver.set_shell` + `Surface.handle_set_shell` (#956)
- Reference implementation: `github.com/ezagent42/json-render-demo` (live: http://100.64.0.27:5173/)

> **Process note (CI now live)**: PRs to `main` are gated by `precommit + check_invariants` (branch protection set 2026-06-24). Rebase onto current `main` and confirm `mix precommit` EXIT=0 **before** returning — a branch must be green on its own tip.
