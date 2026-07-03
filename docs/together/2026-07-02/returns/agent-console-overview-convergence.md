# Return — Agent Console Workstream A: Overview / IA Convergence

> **Task:** Workstream A — PR #1112 Overview / IA Convergence
> **Branch:** `worktree-agent-console-overview-convergence` (off `main` @ `adf5fad5`)
> **PR:** none yet (local worktree branch; push/PR pending lead OK — see §Merge request)
> **Dev:** agent (Claude, orchestrated by gaga)
> **returned_at:** 2026-07-02 17:20 +0800
> **deadline:** 2026-07-02 23:59 +0800
> **deadline_status:** on_time

## Route decision (the discuss-first answer + a scope refinement)

**Question:** Should World `/` route change from Chat/Sessions to Overview?

**Decision: NO for `/` (default landing stays Chat/Sessions). Overview is wired as
a NON-default surface reachable via a new `/overview` route + an "Overview" nav
item.** Whether Overview should become the post-login *first screen* is
**deferred** to Allen (it's a host-model change, not a Workstream-A edit — see
§"Deferred: first-screen landing").

### How the decision evolved (recorded for the ledger)

1. gaga first chose "make `/` the Overview landing." I implemented it end-to-end
   (green locally: world 124/0, web 273/0, arch gates green).
2. The async review flagged that post-login users still land on `/sessions` via
   `HomeLive`. Digging into that revealed a **host-model constraint** (below):
   `/` on the main host is `HomeLive`, so a "land on Overview" redirect would
   loop, and Overview at `/` only exists on the world host.
3. gaga re-scoped (correct call): **keep `/` = Chat, ship Overview behind a
   non-default `/overview` entry so it's reachable + acceptance-testable now, and
   defer the first-screen decision.** This is the handoff's own "if no" branch
   ("keep `/` as Chat; keep Overview as a non-default surface with a clear route").

### Why Overview needed *any* wiring (findings)

On `main`, **Overview was orphaned dead code**: `Routes.route_for/2` never emitted
`component: "overview"`, so the `overview` clauses in `world_live.ex` /
`admin_data.ex` / `slot_registry.ex` were unreachable, and PR #1112 enriched that
dead surface *and* introduced two arch-gate violations. This branch gives Overview
a real route (`/overview`), enriches its payload, and fixes both gates.

## What's done

`/` unchanged (Chat/Sessions). Overview reachable at `/overview` via a 4th nav
item. #1112's two arch-gate violations fixed. 10 files modified + 1 new test.

### Route + nav (non-default Overview entry)
- `routes.ex` — `/` and `/sessions` keep resolving to Chat (unchanged from main);
  **new** `/overview` → `component: "overview"`.
- `router.ex` (ezagent_web) — added `live "/overview", WorldLive` to both world
  scopes (host-constrained world-host scope + the main/apex scope) so `/overview`
  mounts on every deployment.
- `navigation.ex` — `/overview` added to the LiveView patch-target allowlist.
- `world_ia.js` — nav is now `Chat | Agents | Manage | Overview`, with
  `Overview → /overview`; `/` keeps highlighting Chat; `pageTitleForComponent
  ("overview") → "Overview"`.
- `routes_test.exs` / `world_ia_test.mjs` — assert `/` = Chat, `/sessions` = Chat,
  and the new `/overview` = Overview + its nav/active-state.
- `world_host_routing_test.exs` — reverted to `main` (root mount asserts
  `sessions_table` again); no diff vs `main`.

### AdminData enrichment + arch-gate fixes (kept from the first pass)
- `admin_data.ex` — overview state carries `kpis` + `available_sessions`
  (URI-ordered, ≤3) + `session_template_names`. **URI-scan fix:**
  `available_session_rows/1` uses the sanctioned `encode_uri/1` wrapper instead of
  a bare `URI.to_string` in a map value (scanner `uri_string_key` rule).
- `workspace_plugin_data.ex` + `world_live.ex` — **cross-file-duplicate fix:**
  `session_template_names/1` (+ `class_directly_creatable?/1`) relocated to
  `WorkspacePluginData` as the single source of truth; `WorldLive` + `AdminData`
  delegate (was a byte-copy in AdminData → new duplicate group over the cap-42
  baseline).
- `admin_data_test.exs` (new) — 4 tests: payload shape, JSON-safety, nil-workspace
  guard, non-workspace-URI guard.

### Overview.tsx
- #1112's 3-panel rewrite (recommended-next / KPIs / continuable sessions),
  deep-linking to `/sessions?session=`.
- **Review fix (low):** headline "继续「X」" → "进入「X」" — `available_sessions`
  is URI-ordered (not recency), so "continue your latest" was a misleading
  affordance; the neutral "enter" framing matches the data.

## DoD reconciliation

| # | DoD line (from handoff) | status | proof / open decision |
|---|-------------------------|--------|-----------------------|
| 1 | Route semantic decision recorded (PR body or return doc) | met | This doc §"Route decision" — `/` = Chat, Overview at `/overview`, first-screen deferred |
| 2 | `mix test .../world/routes_test.exs` | met | 12 routes tests, 0 failures (incl. `/`=Chat, `/overview`=Overview) |
| 3 | `node .../assets/test/world_ui_structure_test.mjs` | met | all assertions passed (+ `world_ia_test.mjs`, `world_navigation_test.mjs` green) |
| 4 | AdminData / Overview tests (admin_data.ex changed) | met | `admin_data_test.exs` 4/0; `vite build` exit 0 |
| 5 | Architecture gate that previously failed (≥ failing subset) | met | `cross_file_duplicate_fn_test` + `uri_query/scan_test` 15/0; full `architecture/` dir 58/0 at proper timeout; independent review ran the scanners: `cross_file_duplicate_fn_groups 42/42 PASS`, `uri_query.scan` 0 violations |
| 6 | #1112 merge-ready OR closed/superseded, docs preserved | met (recommendation) | Supersede #1112 — §"#1112 disposition". Open item: preserve #1112's IA design doc |

**Additional regression proof:** `world_host_routing_test.exs` 19/0 (root back to
Chat); full `apps/ezagent_plugin_world/test/ezagent/world` 124/0; full umbrella
`mix test` had only (a) ezagent_core arch scanners hitting the 60s ExUnit default
under `max_cases:32` load (green at 300s: 58/0) and (b) one flaky
`EzagentPluginFeishu.WsClientErlexecTest` (green on re-run) — **no regressions from
this change**.

## Deferred: first-screen landing — host-model constraints (reference for later)

> Recorded per gaga's request so whoever revisits "make Overview the post-login
> first screen" has the analysis. **Do not attempt a naive `HomeLive` redirect —
> it loops.**

### The two-host structure (`apps/ezagent_web/lib/ezagent_web/router.ex`)

| Host | `/` resolves to | `/sessions` | `/overview` (new) |
|---|---|---|---|
| **World host** (`world.*`; dev/test/beta — `world_host_scope="world."`) | `WorldLive` → **Chat** | `WorldLive` → Chat | `WorldLive` → Overview |
| **Main / apex** (`world_host_scope=nil` in prod) | **`HomeLive`** (router `live "/", HomeLive`) | `WorldLive` → Chat | `WorldLive` → Overview |

- The world routes live in **two** scopes: a host-constrained world-host scope
  (`host: @world_host_scope`, only compiled when the scope is set) and a
  main/apex scope gated by the `WorldHostScope` plug. Only the **world-host**
  scope has `live "/", WorldLive`; the main/apex scope does **not** — its `/` is
  `HomeLive`.
- `WorldHostScope` (`plugs/world_host_scope.ex`): binary scope ⇒ world routes
  only serve on the `world.`-prefixed host; `nil` ⇒ operator routes serve on the
  apex host (prod).

### Why "land on Overview post-login" is not a one-liner
- The post-login redirect lives in `HomeLive` (`live/home_live.ex`), which **is**
  the main-host `/`. Redirecting it to `/` → re-mounts `HomeLive` → redirects
  again → **infinite loop**.
- Overview at `/` exists **only on the world host**; the main/apex `/` is
  `HomeLive` and has no `/`-Overview route to point at.
- Reaching the world-host Overview from `HomeLive` would need a **cross-host**
  `redirect(external:)`, which is config-dependent (`world_host_scope` prefix) and
  degrades in apex mode (no separate world host).
- Net: in **apex/prod**, Overview-at-`/` doesn't exist at all; the operator app's
  default surface is `/sessions` (Chat) via `HomeLive`.

### Options for a future first-screen change (Allen's call)
1. **Add a main-host Overview route + point `HomeLive` there** (e.g. reuse the new
   `/overview` — non-looping, apex-safe). Lowest-risk realization; `HomeLive`
   redirects authenticated users to `/overview` instead of `/sessions`.
2. **Cross-host redirect** `HomeLive → world-host `/``. Fragile; needs an apex
   fallback guard; couples `HomeLive` to host config.
3. **Restructure the home flow** so `/` = Overview everywhere (move `HomeLive`'s
   first-login wizard). Biggest blast radius; a real IA/host decision.

Reference files: `router.ex` (scopes ~L34–L124), `live/home_live.ex` (redirect at
~L49–L65 + wizard), `plugs/world_host_scope.ex`, `config/{dev,test,prod}.exs`
(`world_host_scope`).

## #1112 disposition — recommendation
**Close #1112 (`fix/agent-console-completeness-0630`) as superseded by this
branch.** #1112 left Overview unreachable and shipped the 2 arch-gate violations;
this branch gives it a real route, fixes both gates, and keeps `/` = Chat.
**Open item:** #1112 also adds `docs/superpowers/specs/2026-07-01-agent-console-
ia-design.md` (378 lines) not on this branch — cherry-pick it in, or land it via a
separate docs-only PR (recommend cherry-pick).

## Branch + gate status (machine return gate)
- **Rebase base:** `main` @ `adf5fad5` (branched fresh off origin/main).
- **CI (`precommit + check_invariants`):** not yet run — branch is local + unpushed
  (no push/PR without explicit OK). Local verification is comprehensive (all target
  suites green); the machine gate (CI on a PR head) is pending a push, which is the
  lead's call. Not self-declaring "READY TO MERGE".
- Local build/deps shared from the main tree via symlinks (`deps`, `_build`, assets
  `node_modules`) only to run tests; excluded from the deliverable.

## Deferred / out of scope
- **Post-login first-screen landing** — deferred to Allen (host-model; see above).
- No `Identities → Roster` / `Capabilities → Access` renames; no `AgentNewForm`
  redesign; no multi-tier Workspace view.
- Session delete/archive lifecycle = Workstream B; broader route-level tests =
  Workstream C (only touched route tests this change required).

## Method friction
- The handoff framed the crux as "does `/` change", but `/` on the **main host** is
  `HomeLive`, not WorldLive — so "make `/` the landing" and "land on Overview
  post-login" are two different things gated by the host model. The dead-code +
  host-model reality is worth stating up front; it's what turned a one-liner into a
  deferred architecture decision.
- Fresh-worktree arch verification is awkward (deps/`_build` unpopulated; the
  `ezagent_web` test-helper rebuilds an esbuild bundle needing `node_modules`
  across asset dirs). Symlinking from the main tree works; a "prime a worktree for
  tests" recipe would save every parallel dev this rediscovery.
- #1123 (tput/precommit) is OTP-28-specific; this machine is 1.18.4/OTP-27 and the
  arch tests ran fine.

## Merge request
- **Branch:** `worktree-agent-console-overview-convergence` → `main`.
- **Order:** independent of B/D (docs) and C (tests); if C touches `routes_test.exs`
  land A first (A owns route semantics). This change is additive on `/` (no default
  behavior change), so blast radius is low.
- **Next step (needs your OK):** commit → push → open PR (supersedes #1112) → CI →
  close #1112 with a pointer here → decide #1112 design-doc preservation.
